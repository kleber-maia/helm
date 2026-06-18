import Cocoa
import SwiftUI
import Combine

/// Identifies the visible state of the commit history: the ordered commits
/// plus the refs (which render as branch/tag labels on rows). Used to skip a
/// full table reload when a refresh didn't actually change anything.
private struct HistorySignature: Equatable
{
  let commitOIDs: [GitOID]
  let refs: [String: GitOID]
}

final class HistoryTableController: NSViewController,
                                    RepositoryWindowViewController
{
  typealias Repository = BasicRepository & FileChangesRepo &
                         CommitStorage & FileContents & Branching
  
  enum ColumnID
  {
    static let commit = ¶"commit"
    static let graph = ¶"graph"
    static let refs = ¶"refs"
  }

  @IBOutlet var contextMenu: NSMenu!
  
  var tableView: HistoryTableView { view as! HistoryTableView }
  let history = GitCommitHistory()
  var repository: any Repository
  { repoController?.repository as! (any Repository) }
  var sinks: [AnyCancellable] = []
  var graphColumnOffset: CGFloat = 0
  private var isLoadingHistory = false
  private var pendingHistoryReload = false
  private var currentBranch: LocalBranchRefName?
  private var lastHistorySignature: HistorySignature?
  
  func finishLoad(repository: any Repository)
  {
    history.repository = repository
    currentBranch = repository.currentBranch

    loadHistory()

    if let repository = repository as? HelmRepository {
      sinks.append(repository.currentBranchPublisher.sinkOnMainQueue {
        [weak self] branch in
        guard let self = self,
              self.currentBranch != branch
        else { return }

        self.currentBranch = branch
        self.tableView.reloadData()
      })
    }

    if let controller = repoUIController {
      sinks.append(contentsOf: [
        controller.repoController.refsPublisher.sinkOnMainQueue {
          [weak self] in
          // To do: dynamic updating
          // - new and changed refs: add if they're not already in the list
          // - deleted and changed refs: recursively remove unreferenced commits

          // For now: just reload
          self?.reload()
        },
        controller.repoController.headPublisher.sinkOnMainQueue {
          [weak self] in
          self?.reload()
        },
        controller.selectionPublisher.sink {
          [weak self] (selection) in
          guard let selection = selection,
                !(selection is StagingSelection)
          else { return }

          self?.selectRow(target: selection.target)
        },
        controller.reselectPublisher.sink {
          [weak self] in
          guard let self,
                let selection = self.repoUIController?.selection
          else { return }

          self.selectRow(target: selection.target, forceScroll: true)
        },
      ])
    }
    else {
      assertionFailure("repoUIController is missing")
    }
  }
  
  public override func viewDidLoad()
  {
    super.viewDidLoad()

    tableView.setAccessibilityIdentifier("history")

    history.postProgress = {
      [weak self] (generation, start, end) in
      self?.batchFinished(generation: generation, start: start, end: end)
    }
  }
  
  public override func viewWillDisappear()
  {
    history.abort()
  }
  
  /// Reloads the commit history from scratch.
  public func reload()
  {
    loadHistory()
  }
  
  func loadHistory()
  {
    if isLoadingHistory {
      pendingHistoryReload = true
      repoLogger.publicInfo("history load pendingReload")
      return
    }

    isLoadingHistory = true
    pendingHistoryReload = false
    repoLogger.publicInfo("history load begin")

    let history = self.history
    let repository = self.repository
    weak let tableView = view as? NSTableView
    
    let generation = history.reset()

    let queue = Thread.syncOnMain { repoUIController?.queue }

    queue?.executeAsync {
      Signpost.intervalStart(.historyWalking, object: self)
      defer {
        Signpost.intervalEnd(.historyWalking, object: self)
      }
      
      guard let walker = repository.walker()
      else {
        repoLogger.debug("RevWalker failed")
        DispatchQueue.main.async {
          [weak self] in
          self?.finishHistoryLoad(generation: generation,
                                  tableView: tableView,
                                  reloadTable: false)
        }
        return
      }
      
      repository.rebuildRefsIndex()
      walker.setSorting([.topological, .time])
      
      let refs = repository.allRefs()
      repoLogger.publicInfo("history walk refs count=\(refs.count)")

      var refOIDs = [String: GitOID]()

      for ref in refs where ref.fullPath != "refs/stash" {
        if let oid = repository.oid(forRef: ref) {
          refOIDs[ref.fullPath] = oid
          walker.push(oid: oid)
        }
      }

      history.withSync {
        history.appendCommits(walker.compactMap {
          repository.commit(forOID: $0) as? GitCommit
        })
      }

      let signature = HistorySignature(
          commitOIDs: history.withSync { history.entries.map { $0.commit.id } },
          refs: refOIDs)
      repoLogger.publicInfo("""
          history walk end generation=\(generation) \
          commits=\(history.withSync { history.entries.count })
          """)
      
      DispatchQueue.global(qos: .utility).async {
        // Get off the queue thread, but run this as a queue task so that
        // progress will be displayed.
        queue?.executeTask {
          Signpost.interval(.connectCommits) {
            history.processFirstBatch()
          }
        }
        DispatchQueue.main.async {
          [weak self] in
          self?.finishHistoryLoad(generation: generation,
                                  tableView: tableView,
                                  reloadTable: true,
                                  signature: signature)
        }
      }
    }
  }

  private func finishHistoryLoad(generation: Int,
                                 tableView: NSTableView?,
                                 reloadTable: Bool,
                                 signature: HistorySignature? = nil)
  {
    guard history.isCurrentGeneration(generation)
    else {
      repoLogger.publicInfo("""
          history load ignored generation=\(generation) reason=stale
          """)
      return
    }

    isLoadingHistory = false

    if pendingHistoryReload {
      repoLogger.publicInfo("""
          history load restart generation=\(generation) reason=pendingReload
          """)
      loadHistory()
      return
    }

    guard reloadTable
    else {
      repoLogger.publicInfo("""
          history load end generation=\(generation) reload=false
          """)
      return
    }

    // Nothing visibly changed (same commits, same refs): skip the full
    // reload so the table doesn't flash and the selection/scroll stay put.
    if let signature = signature,
       signature == lastHistorySignature {
      repoLogger.publicInfo("""
          history load end generation=\(generation) reload=skipped \
          reason=unchanged
          """)
      return
    }
    lastHistorySignature = signature

    updateGraphColumnOffset()
    tableView?.reloadData()
    ensureSelection()
    updateHeadGraphColor()
    repoLogger.publicInfo("""
        history load end generation=\(generation) reload=true \
        rows=\(history.withSync { history.entries.count })
        """)
  }
  
  /// Notifier for history processing progress
  /// - parameter start: Row where the batch started
  /// - parameter end: Row where the batch ended
  nonisolated
  func batchFinished(generation: Int, start: Int, end: Int)
  {
    DispatchQueue.main.async {
      [weak self] in
      guard let self,
            self.history.isCurrentGeneration(generation),
            !self.isLoadingHistory,
            !self.pendingHistoryReload
      else { return }

      let tableView = self.tableView
      
      let batchRange = start..<end

      self.updateGraphColumnOffset()
      
      tableView.enumerateAvailableRowViews {
        (rowView, row) in
        guard batchRange.contains(row)
        else { return }
        
        for column in 0..<rowView.numberOfColumns {
          if let cellView = rowView.view(atColumn: column) as? HistoryCellView {
            cellView.needsUpdateConstraints = true
            cellView.needsLayout = true
            cellView.needsDisplay = true
          }
        }
        if rowView.numberOfColumns == 0 {
          rowView.needsDisplay = true
        }
      }
      self.updateHeadGraphColor()
    }
  }

  func updateGraphColumnOffset()
  {
    guard let graphColumn = tableView.columnObject(
              withIdentifier: ColumnID.graph),
          !graphColumn.isHidden
    else { return }

    let maxColumn = history.withSync { history.maxColumnSeen }
    let contentWidth = HistoryCellView.graphContentWidth(maxColumn: maxColumn)
    let newOffset = max(0, (graphColumn.width - contentWidth) / 2)

    guard newOffset != graphColumnOffset
    else { return }

    graphColumnOffset = newOffset

    tableView.enumerateAvailableRowViews {
      (rowView, row) in
      for column in 0..<rowView.numberOfColumns {
        guard let cellView = rowView.view(atColumn: column)
                          as? HistoryCellView
        else { continue }

        cellView.graphOffset = graphColumnOffset
        cellView.needsDisplay = true
      }
    }
  }

  private func updateHeadGraphColor()
  {
    guard let headOID = repository.headOID,
          let entry = history.withSync({
            history.entries.first { $0.commit.id == headOID }
          }),
          let colorIndex = entry.dotColorIndex
    else { return }

    let color = HistoryCellView.lineColors[
        Int(colorIndex) % HistoryCellView.lineColors.count]

    (repoUIController as? HelmWindowController)?
        .tabbedSidebarController?.coordinator
        .headGraphColor = Color(nsColor: color)
  }
  
  func ensureSelection()
  {
    guard let tableView = view as? NSTableView,
          tableView.selectedRowIndexes.isEmpty
    else { return }
    
    guard let selection = repoUIController?.selection
    else { return }
    
    selectRow(target: selection.target, forceScroll: true)
  }
  
  /// Selects the row for the given commit SHA.
  func selectRow(target: SelectionTarget, forceScroll: Bool = false)
  {
    let tableView = view as! NSTableView
    
    objc_sync_enter(self)
    history.syncMutex.lock()
    defer {
      history.syncMutex.unlock()
      objc_sync_exit(self)
    }
    
    guard let oid = target.oid,
          let row = history.entries.firstIndex(where: { $0.commit.id == oid })
    else {
      tableView.deselectAll(self)
      return
    }
    guard tableView.selectedRow != row || tableView.numberOfSelectedRows != 1
    else { return }
    
    tableView.selectRowIndexes(IndexSet(integer: row),
                               byExtendingSelection: false)
    if forceScroll || (view.window?.firstResponder !== tableView) {
      tableView.scrollRowToCenter(row)
    }
  }
  
  public func refreshText()
  {
    for rowIndex in tableView.visibleRows() {
      guard let rowView = tableView.rowView(atRow: rowIndex,
                                            makeIfNecessary: false)
      else { continue }
      
      for column in 0..<rowView.numberOfColumns {
        guard let cellView = rowView.view(atColumn: column) as? NSTableCellView
        else { continue }
        
        setCellTextColor(cellView, index: rowIndex)
      }
    }
  }
  
  func setCellTextColor(_ cellView: NSTableCellView, index: Int)
  {
    let entry = history.entries[index]
    let deemphasized = (entry.commit.parentOIDs.count > 1) &&
                       UserDefaults.helm.deemphasizeMerges

    if let textField = cellView.textField {
      textField.textColor = deemphasized
          ? NSColor.disabledControlTextColor
          : NSColor.controlTextColor
    }
    else if let historyCellView = cellView as? HistoryCellView {
      historyCellView.deemphasized = deemphasized
    }
  }
}

extension HistoryTableController: NSTableViewDelegate
{
  public func displayString(name: String?, email: String?) -> String
  {
    if let name = name {
      if let email = email {
        return "\(name) <\(email)>"
      }
      else {
        return name
      }
    }
    else {
      return email ?? "—"
    }
  }

  public func tableView(_ tableView: NSTableView,
                        viewFor tableColumn: NSTableColumn?,
                        row: Int) -> NSView?
  {
    guard repoController != nil
    else { return nil }
    let visibleRowCount =
          tableView.rows(in: tableView.enclosingScrollView!.bounds).length
    let (entryCount, batchStart) = history.withSync {
      (history.entries.count, history.batchStart)
    }
    let firstProcessRow = min(entryCount, row + visibleRowCount)
    
    if firstProcessRow > batchStart
    {
      history.processBatches(throughRow: firstProcessRow,
                             queue: repoUIController?.queue)
    }
    
    guard (row >= 0) && (row < entryCount)
    else {
      NSLog("Object value request out of bounds")
      return nil
    }
    guard let tableColumn = tableColumn,
          let result = tableView.makeView(withIdentifier: tableColumn.identifier,
                                          owner: self) as? NSTableCellView
    else { return nil }
    
    let entry = history.entries[row]

    switch tableColumn.identifier {
      
      case ColumnID.commit:
        let historyCell = result as! HistoryCellView
        let graphColumnVisible =
              !(tableView.columnObject(withIdentifier: ColumnID.graph)?.isHidden
                ?? true)

        historyCell.displayMode = graphColumnVisible ? .titleOnly : .all
        historyCell.configure(entry: entry, repository: repository,
                              currentBranch: currentBranch)
        historyCell.mutex = history.syncMutex

      case ColumnID.graph:
        let historyCell = result as! HistoryCellView

        historyCell.displayMode = .graphOnly
        historyCell.graphOffset = graphColumnOffset
        historyCell.configure(entry: entry, repository: repository,
                              currentBranch: currentBranch)
        historyCell.mutex = history.syncMutex

      case ColumnID.refs:
        let refsCell = result as! HistoryCellView

        refsCell.displayMode = .refsOnly
        refsCell.configure(entry: entry, repository: repository,
                           currentBranch: currentBranch)
        refsCell.mutex = history.syncMutex

      default:
        return nil
    }
    
    setCellTextColor(result, index: row)
    
    return result
  }
 
  public func tableViewSelectionDidChange(_ notification: Notification)
  {
    guard view.window?.firstResponder === view,
          let tableView = notification.object as? NSTableView
    else { return }
    
    let selectedRow = tableView.selectedRow
    
    if (selectedRow >= 0) && (selectedRow < history.entries.count) {
      repoUIController?.selection =
          CommitSelection(repository: repository,
                          commit: history.entries[selectedRow].commit)
    }
  }


}

extension HistoryTableController: HelmTableViewDelegate
{
  func tableViewClickedSelectedRow(_ tableView: NSTableView)
  {
    guard let selectionIndex = tableView.selectedRowIndexes.first,
          let controller = repoUIController
    else { return }
    
    let entry = history.entries[selectionIndex]
    let newSelection = CommitSelection(repository: repository,
                                       commit: entry.commit)
    
    if (controller.selection == nil) ||
       (controller.selection?.target != newSelection.target) ||
       (type(of: controller.selection!) != type(of: newSelection)) {
      controller.selection = newSelection
    }
  }
  
  func menu(forRow row: Int, column: Int) -> NSMenu?
  {
    guard row >= 0
    else { return nil }
    
    return contextMenu
  }
}

extension HistoryTableController: NSTableViewDataSource
{
  public func numberOfRows(in tableView: NSTableView) -> Int
  {
    objc_sync_enter(history)
    defer {
      objc_sync_exit(history)
    }
    return history.entries.count
  }
}
