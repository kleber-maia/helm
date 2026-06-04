import Cocoa

/// Represents a section header ("Staged" / "Unstaged") in the combined
/// review tree.
class StagingSectionItem
{
  let title: String
  let isStaged: Bool
  var root: FileChangeNode

  init(title: String, isStaged: Bool)
  {
    self.title = title
    self.isStaged = isStaged
    self.root = FileChangeNode(value: FileChange(path: title))
  }
}

/// Data source that presents staged and unstaged files as two expandable
/// root sections in a single `NSOutlineView`.
final class StagingTreeDataSource: FileListDataSourceBase
{
  let stagedSection: StagingSectionItem
  let unstagedSection: StagingSectionItem
  private var sections: [StagingSectionItem]
  { [stagedSection, unstagedSection] }

  /// Object identifiers of all nodes in the staged tree, for O(1) lookup.
  private(set) var stagedNodeIDs = Set<ObjectIdentifier>()

  /// Called on the main queue after each reload finishes, with
  /// `true` when both sections are empty (no pending changes).
  var onReloadComplete: ((_ isEmpty: Bool) -> Void)?

  weak var workspaceDelegate: (any FileListDelegate)?

  override init(useWorkspaceList: Bool)
  {
    stagedSection = StagingSectionItem(
        title: UIString.staged.rawValue, isStaged: true)
    unstagedSection = StagingSectionItem(
        title: "Unstaged", isStaged: false)

    super.init(useWorkspaceList: useWorkspaceList)
  }

  convenience init()
  {
    self.init(useWorkspaceList: false)
  }

  /// Walks the outline view parent chain to find which section an item
  /// belongs to.
  func section(for item: Any,
               in outlineView: NSOutlineView) -> StagingSectionItem?
  {
    var current: Any? = item
    while let candidate = current {
      if let section = candidate as? StagingSectionItem {
        return section
      }
      current = outlineView.parent(forItem: candidate)
    }
    return nil
  }

  /// Returns `true` if the item belongs to the staged tree.
  func isItemStaged(_ item: Any) -> Bool
  {
    if let section = item as? StagingSectionItem {
      return section.isStaged && !section.root.children.isEmpty
    }
    if let node = item as? FileChangeNode {
      return stagedNodeIDs.contains(ObjectIdentifier(node))
    }
    return false
  }

  private func collectNodeIDs(
      from root: FileChangeNode) -> Set<ObjectIdentifier>
  {
    var ids = Set<ObjectIdentifier>()

    func walk(_ node: FileChangeNode)
    {
      ids.insert(ObjectIdentifier(node))
      for child in node.children {
        walk(child)
      }
    }
    walk(root)
    return ids
  }
}

// MARK: FileListDataSource
extension StagingTreeDataSource: FileListDataSource
{
  func reload()
  {
    guard let repoUIController = self.repoUIController,
          let selection =
              repoUIController.selection as? StagedUnstagedSelection
    else { return }

    let stagedList = selection.fileList
    let unstagedList = selection.unstagedFileList

    if let delegate = workspaceDelegate {
      delegate.configure(model: unstagedList)
    }

    repoUIController.queue.executeAsync {
      [weak self] in
      guard let self = self
      else { return }

      let (oldStaged, oldUnstaged) = await MainActor.run {
        (TreeNodeContainer(node: self.stagedSection.root),
         TreeNodeContainer(node: self.unstagedSection.root))
      }

      let newStagedRoot = stagedList.treeRoot(oldTree: oldStaged.node)
      let newUnstagedRoot = unstagedList.treeRoot(
          oldTree: oldUnstaged.node)

      await MainActor.run {
        guard let outlineView = self.outlineView
        else { return }

        let selectedRow = outlineView.selectedRow
        let selectedChange = self.fileChange(at: selectedRow)

        self.stagedSection.root = newStagedRoot
        self.unstagedSection.root = newUnstagedRoot
        self.stagedNodeIDs = self.collectNodeIDs(
            from: newStagedRoot)

        outlineView.reloadData()
        self.expandAll()
        self.reselect(item: selectedChange, oldRow: selectedRow)

        let empty = newStagedRoot.children.isEmpty
            && newUnstagedRoot.children.isEmpty
        self.onReloadComplete?(empty)
      }
    }
  }

  func fileChange(at row: Int) -> FileChange?
  {
    guard let outlineView = outlineView,
          row >= 0, row < outlineView.numberOfRows
    else { return nil }

    return (outlineView.item(atRow: row) as? FileChangeNode)?.value
  }

  func path(for item: Any) -> String
  {
    if let section = item as? StagingSectionItem {
      return section.title
    }
    return (item as? FileChangeNode)?.value.gitPath ?? ""
  }

  func change(for item: Any) -> DeltaStatus
  {
    if item is StagingSectionItem { return .mixed }
    return (item as? FileChangeNode)?.value.status ?? .unmodified
  }
}

// MARK: NSOutlineViewDataSource
extension StagingTreeDataSource: NSOutlineViewDataSource
{
  func outlineView(_ outlineView: NSOutlineView,
                   numberOfChildrenOfItem item: Any?) -> Int
  {
    if item == nil { return sections.count }
    if let section = item as? StagingSectionItem {
      return section.root.children.count
    }
    if let node = item as? FileChangeNode {
      return node.children.count
    }
    return 0
  }

  func outlineView(_ outlineView: NSOutlineView,
                   isItemExpandable item: Any) -> Bool
  {
    if item is StagingSectionItem { return true }
    if let node = item as? FileChangeNode {
      return !node.children.isEmpty
    }
    return false
  }

  func outlineView(_ outlineView: NSOutlineView,
                   child index: Int,
                   ofItem item: Any?) -> Any
  {
    if item == nil { return sections[index] }
    if let section = item as? StagingSectionItem {
      let children = section.root.children
      guard index < children.count
      else { return FileChangeNode() }
      return children[index]
    }
    if let node = item as? FileChangeNode {
      guard index < node.children.count
      else { return FileChangeNode() }
      return node.children[index]
    }
    return FileChangeNode()
  }

  func outlineView(_ outlineView: NSOutlineView,
                   objectValueFor tableColumn: NSTableColumn?,
                   byItem item: Any?) -> Any?
  {
    if let section = item as? StagingSectionItem {
      return section.title
    }
    return (item as? FileChangeNode)?.value
  }
}

// MARK: Expansion & Selection Helpers
private extension StagingTreeDataSource
{
  func expandAll()
  {
    guard let outlineView = outlineView
    else { return }
    outlineView.expandItem(nil, expandChildren: true)
  }

  func reselect(item: FileChange?, oldRow: Int)
  {
    guard let item = item,
          let outlineView = outlineView
    else { return }

    // Fast path: check if the same file is still at the old row.
    if let oldRowNode = outlineView.item(atRow: oldRow)
                          as? FileChangeNode,
       oldRowNode.value.gitPath == item.gitPath
    {
      outlineView.selectRowIndexes(IndexSet(integer: oldRow),
                                   byExtendingSelection: false)
      return
    }

    // The file moved (e.g. after staging a hunk). Scan all rows.
    for row in 0..<outlineView.numberOfRows {
      if let node = outlineView.item(atRow: row) as? FileChangeNode,
         node.value.gitPath == item.gitPath
      {
        outlineView.selectRowIndexes(IndexSet(integer: row),
                                     byExtendingSelection: false)
        return
      }
    }
  }
}
