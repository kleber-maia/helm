import Cocoa
import Combine

/// Unified file list controller for the Review panel. Shows a single
/// outline view with two root sections — Staged and Unstaged — each
/// containing a file tree. Action buttons (stage / unstage) are
/// rendered per-section.
final class ReviewFileListController: FileListController
{
  let stagingDataSource = StagingTreeDataSource()
  var indexSink: AnyCancellable?
  var modifyActions: [Selector] = []

  init()
  {
    super.init(isWorkspace: false)
  }

  required init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }

  required init(isWorkspace: Bool)
  {
    fatalError("Use init() instead")
  }

  override func loadView()
  {
    super.loadView()

    // Switch to the combined staging data source
    stagingDataSource.outlineView = outlineView
    viewDataSource = stagingDataSource

    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(.FileList.Staged.group)
    view.setAccessibilityRole(.group)
    outlineView.setAccessibilityIdentifier(.FileList.Staged.list)

    listTypeIcon.image = .xtStaged
    listTypeLabel.uiStringValue = .files

    // Add vertical breathing room between rows
    outlineView.intercellSpacing = NSSize(width: 3, height: 6)

    addModifyingToolbarButton(
        image: .xtRefresh,
        toolTip: .refresh,
        target: self,
        action: #selector(refreshStaging(_:)),
        accessibilityID: "WorkspaceRefresh")
    addModifyingToolbarButton(
        image: .xtUnstageAll,
        toolTip: .unstageAll,
        action: #selector(unstageAll(_:)))
    addModifyingToolbarButton(
        image: .xtStageAll,
        toolTip: .stageAll,
        action: #selector(stageAll(_:)))
    addModifyingToolbarButton(
        image: .xtUndo,
        toolTip: .revert,
        action: #selector(revert(_:)))
  }

  override func finishLoad(controller: any RepositoryUIController)
  {
    // Skip super — the inherited fileTreeDataSource is unused and
    // wiring it up causes spurious reloads / crashes.
    stagingDataSource.repoUIController = controller

    guard stagingDataSource.isReviewPanel
    else { return }

    indexSink = controller.repoController.indexPublisher
      .sinkOnMainQueue {
        [weak self] in
        self?.stagingDataSource.reload()
      }
  }

  // MARK: - Toolbar Helpers

  func addModifyingToolbarButton(image: NSImage,
                                 toolTip: UIString,
                                 target: Any? = nil,
                                 action: Selector,
                                 accessibilityID: String? = nil)
  {
    modifyActions.append(action)
    addToolbarButton(image: image, toolTip: toolTip,
                     target: target ?? self, action: action,
                     accessibilityID: accessibilityID)
  }

  func setActionColumnShown(_ shown: Bool)
  {
    outlineView.columnObject(withIdentifier: ColumnID.action)?
        .isHidden = !shown
  }

  func setWorkspaceControlsShown(_ shown: Bool)
  {
    for case let button as NSButton in toolbarStack.arrangedSubviews {
      switch button.action {
        case #selector(stageAll(_:)),
             #selector(unstageAll(_:)),
             #selector(revert(_:)),
             #selector(refreshStaging(_:)):
          button.isHidden = !shown
        default:
          break
      }
    }
  }

  var canModify: Bool
  { !(repoSelection is StashSelection) }

  override func repoSelectionChanged()
  {
    for action in modifyActions {
      toolbarButton(withAction: action)?.isHidden = !canModify
    }
  }

  // MARK: - Stage / Unstage Actions

  @IBAction
  override func stage(_ sender: Any)
  {
    let changes = targetChanges(sender: sender)
    guard !changes.isEmpty
    else { return }

    performFileMutation {
      for change in changes {
        try self.repository.stage(change: change)
      }
    }
  }

  @IBAction
  override func unstage(_ sender: Any)
  {
    let changes = targetChanges(sender: sender)
    guard !changes.isEmpty
    else { return }

    performFileMutation {
      for change in changes {
        try self.repository.unstage(change: change)
      }
    }
  }

  @objc func toggleStaging(_ sender: Any)
  {
    guard let checkbox = sender as? NSButton
    else { return }
    let row = outlineView.row(for: checkbox)
    guard row >= 0,
          let item = outlineView.item(atRow: row)
    else { return }

    // Section header: stage all / unstage all
    if let section = item as? StagingSectionItem {
      if section.isStaged {
        performFileMutation {
          try self.repoUIController?.repository.unstageAllFiles()
        }
      }
      else {
        performFileMutation {
          try self.repoUIController?.repository.stageAllFiles()
        }
      }
      return
    }

    // Collect all leaf file changes under this item
    let changes = collectChanges(under: item)

    guard !changes.isEmpty
    else { return }

    let isStaged = stagingDataSource.isItemStaged(item)

    performFileMutation {
      for change in changes {
        if isStaged {
          try self.repository.unstage(change: change)
        }
        else {
          try self.repository.stage(change: change)
        }
      }
    }
  }

  /// Counts all leaf (file) nodes under a root tree node.
  static func leafCount(in root: FileChangeNode) -> Int
  {
    root.children.reduce(0) { $0 + leafCountRecursive($1) }
  }

  private static func leafCountRecursive(
      _ node: FileChangeNode) -> Int
  {
    if node.isLeaf { return 1 }
    return node.children.reduce(0) { $0 + leafCountRecursive($1) }
  }

  /// Recursively collects all leaf `FileChange` values under an item.
  private func collectChanges(under item: Any) -> [FileChange]
  {
    guard let node = item as? FileChangeNode
    else { return [] }

    if node.isLeaf {
      return [node.value]
    }
    return node.children.flatMap { collectChanges(under: $0) }
  }

  @objc func refreshStaging(_ sender: Any?)
  {
    repoController?.invalidateIndex()
    stagingDataSource.reload()
  }

  /// Returns `true` when the currently selected item is under the
  /// Staged section.
  func isSelectedItemStaged() -> Bool
  {
    guard let selectedRow = outlineView.selectedRowIndexes.first,
          let item = outlineView.item(atRow: selectedRow)
    else { return true }

    return stagingDataSource.isItemStaged(item)
  }
}

// MARK: - NSOutlineViewDelegate overrides
extension ReviewFileListController
{
  override func outlineView(_ outlineView: NSOutlineView,
                            viewFor tableColumn: NSTableColumn?,
                            item: Any) -> NSView?
  {
    guard let columnID = tableColumn?.identifier
    else { return nil }

    // ── Action column: checkbox for every item ─────────────────
    if columnID == ColumnID.action {
      let checkID = ¶"stagingCheckbox"
      let wrapper: NSTableCellView
      let checkbox: NSButton

      if let existing = outlineView.makeView(
              withIdentifier: checkID,
              owner: self) as? NSTableCellView,
         let btn = existing.subviews.first as? NSButton {
        wrapper = existing
        checkbox = btn
      }
      else {
        let btn = NSButton(checkboxWithTitle: "",
                           target: nil, action: nil)

        btn.controlSize = .small
        btn.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()

        cell.identifier = checkID
        cell.addSubview(btn)
        NSLayoutConstraint.activate([
          btn.leadingAnchor.constraint(
              equalTo: cell.leadingAnchor),
          btn.centerYAnchor.constraint(
              equalTo: cell.centerYAnchor),
        ])
        wrapper = cell
        checkbox = btn
      }

      checkbox.target = self
      checkbox.action = #selector(toggleStaging(_:))
      checkbox.state = stagingDataSource.isItemStaged(item)
          ? .on : .off
      return wrapper
    }

    // ── Section headers ──────────────────────────────────────────
    if let section = item as? StagingSectionItem {
      guard columnID == ColumnID.file
      else { return nil }

      guard let cell = outlineView.makeView(
          withIdentifier: CellViewID.fileCell,
          owner: self) as? FileCellView
      else { return nil }

      let count = Self.leafCount(in: section.root)

      cell.textField?.stringValue = "\(section.title) (\(count))"
      cell.textField?.textColor = .secondaryLabelColor
      cell.imageView?.image = section.isStaged
          ? .xtStaged
          : NSImage(systemSymbolName: "folder",
                    accessibilityDescription: nil)
      cell.statusImage.isHidden = true
      cell.change = .unmodified
      return cell
    }

    // ── File column: use the base implementation ─────────────────
    return super.outlineView(outlineView, viewFor: tableColumn,
                             item: item)
  }
}

// MARK: - NSUserInterfaceValidations
extension ReviewFileListController
{
  override func validateUserInterfaceItem(
      _ item: NSValidatedUserInterfaceItem) -> Bool
  {
    let menuItem = item as? NSMenuItem

    switch item.action {
      case #selector(stage(_:)):
        menuItem?.isHidden = !canModify
        return selectedChange != nil
      case #selector(unstage(_:)):
        menuItem?.isHidden = !canModify
        return selectedChange != nil
      case #selector(stageAll(_:)):
        menuItem?.isHidden = !canModify
        return stagingDataSource.unstagedSection.root.children
            .count > 0
      case #selector(unstageAll(_:)):
        menuItem?.isHidden = !canModify
        return stagingDataSource.stagedSection.root.children
            .count > 0
      case #selector(showIgnored(_:)):
        menuItem?.isHidden = !canModify
        return true
      case #selector(revert(_:)):
        menuItem?.isHidden = !canModify
        return selectedChange != nil
      default:
        return super.validateUserInterfaceItem(item)
    }
  }
}
