import Cocoa
import Combine
import UniformTypeIdentifiers

class FileListController: NSViewController, RepositoryWindowViewController
{
  enum ColumnID
  {
    static let action = ¶"action"
    static let file = ¶"file"
    static let hidden = ¶"hidden"
  }
  
  /// Table cell view identifiers for the file list
  enum CellViewID
  {
    static let action = ¶"action"
    static let fileCell = ¶"fileCell"
  }
  
  @IBOutlet weak var listTypeIcon: NSImageView!
  @IBOutlet weak var listTypeLabel: NSTextField!
  @IBOutlet weak var viewSwitch: NSSegmentedControl!
  @IBOutlet weak var toolbarStack: NSStackView!
  @IBOutlet weak var actionButton: NSPopUpButton!
  @IBOutlet weak var outlineView: FileListView!
  {
    didSet
    {
      fileTreeDataSource.outlineView = outlineView
      outlineView.dataSource = viewDataSource
      outlineView.delegate = self
      outlineView.outlineTableColumn =
          outlineView.columnObject(withIdentifier: ColumnID.file)
    }
  }
  
  var viewDataSource: (FileListDataSourceBase &
                       FileListDataSource &
                       NSOutlineViewDataSource)!
  {
    didSet
    {
      outlineView?.dataSource = viewDataSource
    }
  }
  
  let fileTreeDataSource: FileTreeDataSource
  
  var actionImage: NSImage? { nil }
  var pressedImage: NSImage? { nil }
  var actionButtonSelector: Selector? { nil }

  typealias Repository = any BasicRepository & FileStaging & FileContents

  var repository: Repository
  { repoController?.repository as! Repository }

  required init(isWorkspace: Bool)
  {
    self.fileTreeDataSource = FileTreeDataSource(useWorkspaceList: isWorkspace)

    super.init(nibName: "FileListView", bundle: nil)

    viewDataSource = fileTreeDataSource
  }
  
  required init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func loadView()
  {
    super.loadView()
    outlineView.intercellSpacing = NSSize(width: 3, height: 6)
    applyLiquidGlassStyling()
    updateButtons()

    // Remove the list/outline view toggle — always tree view.
    // The XIB had trailing constraints through viewSwitch; pin
    // the toolbar stack to the trailing edge to replace them.
    if let vs = viewSwitch, let header = vs.superview {
      vs.removeFromSuperview()
      toolbarStack.trailingAnchor.constraint(
          equalTo: header.trailingAnchor).isActive = true
    }

    // Remove the Sort By menu (always sorted by full path)
    if let menu = actionButton.menu,
       let sortByItem = menu.item(withIdentifier: ◊"sortBy") {
      let index = menu.index(of: sortByItem)

      menu.removeItem(at: index)
      // Remove the separator that followed
      if index < menu.numberOfItems,
         menu.item(at: index)?.isSeparatorItem == true {
        menu.removeItem(at: index)
      }
    }
  }

  func applyLiquidGlassStyling()
  {
    outlineView.backgroundColor = .clear
    if let scrollView = outlineView.enclosingScrollView {
      scrollView.drawsBackground = false
      scrollView.backgroundColor = .clear
      scrollView.contentView.drawsBackground = false
    }

    // Clear the visual effect and add thin separator lines
    // like the History table header.
    if let header = listTypeIcon.superview as? NSVisualEffectView {
      header.material = .contentBackground
      header.addBorderLines()
    }

    actionButton.bezelStyle = .recessed
    actionButton.controlSize = .small
  }

  // The controller must be passed in because at this point the window isn't
  // set yet.
  func finishLoad(controller: any RepositoryUIController)
  {
    fileTreeDataSource.repoUIController = controller
  }
  
  // These are implemented in subclasses, and are here for convenience
  // in hooking up xib items
  @IBAction func stage(_ sender: Any) {}
  @IBAction func unstage(_ sender: Any) {}
  
  @IBAction
  func stageAll(_ sender: Any)
  {
    performFileMutation {
      try self.repoUIController?.repository.stageAllFiles()
    }
  }
  
  @IBAction
  func unstageAll(_ sender: Any)
  {
    performFileMutation {
      try self.repoUIController?.repository.unstageAllFiles()
    }
  }
  
  @IBAction
  func revert(_ sender: Any)
  {
    // Expand any selected folders into the file changes in their sub-tree
    // so we revert each file individually — git can't revert a directory.
    let nodes = targetNodes(sender: sender)
    let changes = nodes.flatMap { $0.leafChanges }

    guard !changes.isEmpty,
          let window = view.window
    else { return }

    let message: UIString = nodes.count == 1
        ? .confirmRevert(nodes[0].value.path.lastPathComponent)
        : .confirmRevertMultiple

    NSAlert.confirm(message: message, actionName: .revert,
                    isDestructive: true, parentWindow: window) {
      self.performFileMutation {
        for change in changes {
          try self.repository.revert(file: change.gitPath)
        }
      }
    }
  }

  func performFileMutation(_ mutation: @escaping () throws -> Void)
  {
    guard let queue = repoUIController?.repoController.queue
    else { return }

    queue.executeOffMainThread {
      [weak self] in
      do {
        try mutation()
        Task { @MainActor in
          self?.repoUIController?.repoController.indexChanged()
        }
      }
      catch let error as RepoError {
        Task { @MainActor in
          self?.repoUIController?.showErrorMessage(error: error)
          self?.repoUIController?.repoController.indexChanged()
        }
      }
      catch {
        let message = UIString(rawValue: error.localizedDescription)

        Task { @MainActor in
          self?.repoUIController?.showAlert(message: message, info: .empty)
          self?.repoUIController?.repoController.indexChanged()
        }
      }
    }
  }
  
  @IBAction
  func showIgnored(_ sender: Any)
  {
  }
  
  @IBAction
  func open(_ sender: Any)
  {
    for change in targetChanges(sender: sender) {
      let url = repository.fileURL(change.gitPath)
      
      NSWorkspace.shared.open(url)
    }
  }

  @IBAction
  func openInApp(_ sender: NSMenuItem)
  {
    guard let url = sender.representedObject as? URL,
          let item = selectedChange
    else { return }
    let itemURL = repository.fileURL(item.path)

    NSWorkspace.shared.open([itemURL], withApplicationAt: url,
                            configuration: NSWorkspace.OpenConfiguration())
  }
  
  @IBAction
  func showInFinder(_ sender: Any)
  {
    let changes = targetChanges(sender: sender)
    let urls = changes.compactMap { repository.fileURL($0.gitPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }

    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @IBAction
  func copyFileName(_ sender: Any)
  {
    let names = targetChanges(sender: sender)
                  .map { $0.path.lastPathComponent }

    guard !names.isEmpty
    else { return }
    let pasteboard = NSPasteboard.general

    pasteboard.clearContents()
    pasteboard.setString(names.joined(separator: "\n"), forType: .string)
  }
  
  /// Subclasses may want to do something when this happens.
  func repoSelectionChanged()
  {
  }
  
  /// The file change item for the row that is the target of a context menu click
  var clickedChange: FileChange?
  {
    guard let clickedRow = outlineView.contextMenuRow,
          !outlineView.selectedRowIndexes.contains(clickedRow)
    else { return nil }
    
    return viewDataSource.fileChange(at: clickedRow)
  }
  
  /// The file change item for the selected row in the list
  var selectedChange: FileChange?
  {
    guard let index = outlineView.contextMenuRow ??
                      outlineView.selectedRowIndexes.first
    else { return nil }
    
    return viewDataSource?.fileChange(at: index)
  }
  
  var selectedChanges: [FileChange]
  {
    outlineView.selectedRowIndexes.compactMap {
      viewDataSource?.fileChange(at: $0)
    }
  }
  
  /// If `sender` is a button in a file list row, returns the file change for
  /// that row.
  func buttonChange(sender: Any?) -> FileChange?
  {
    guard let button = sender as? NSButton
    else { return nil }
    let row = outlineView.row(for: button)
    
    return viewDataSource.fileChange(at: row)
  }
  
  /// Returns the file changes that are the target of the current action,
  /// depending on how the command was selected
  func targetChanges(sender: Any? = nil) -> [FileChange]
  {
    if let single = buttonChange(sender: sender) ?? clickedChange {
      return [single]
    }
    else {
      return selectedChanges
    }
  }

  /// The outline view nodes that are the target of the current action.
  /// Mirrors `targetChanges(sender:)` but keeps folder nodes intact so
  /// callers can walk their whole sub-tree.
  func targetNodes(sender: Any? = nil) -> [FileChangeNode]
  {
    if let button = sender as? NSButton,
       let rowNode = node(atRow: outlineView.row(for: button)) {
      return [rowNode]
    }

    if let clickedRow = outlineView.contextMenuRow,
       !outlineView.selectedRowIndexes.contains(clickedRow),
       let clicked = node(atRow: clickedRow) {
      return [clicked]
    }

    return outlineView.selectedRowIndexes.compactMap { node(atRow: $0) }
  }

  private func node(atRow row: Int) -> FileChangeNode?
  {
    guard row >= 0, row < outlineView.numberOfRows
    else { return nil }

    return outlineView.item(atRow: row) as? FileChangeNode
  }

  func addToolbarButton(image: NSImage,
                        toolTip: UIString,
                        target: Any? = nil,
                        action: Selector,
                        accessibilityID: String? = nil)
  {
    let button = NSButton(image: image, target: target ?? self, action: action)
  
    button.toolTip = toolTip.rawValue
    button.setFrameSize(NSSize(width: 26, height: 18))
    button.bezelStyle = .smallSquare
    button.isBordered = false
    toolbarStack.insertView(button, at: 0, in: .leading)
    button.widthAnchor.constraint(equalToConstant: 20).isActive = true
    button.setAccessibilityIdentifier(accessibilityID)
  }
  
  func toolbarButton(withAction action: Selector) -> NSButton?
  {
    return toolbarStack.subviews.firstOfType(where: {
      (button: NSButton) in button.action == action
    })
  }
  
  func updateButtons()
  {
    for button in toolbarStack.subviews.compactMap({ $0 as? NSButton })
        where button != actionButton {
      button.isEnabled = validateUserInterfaceItem(button)
    }
  }
}

extension FileListController: NSUserInterfaceValidations
{
  func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
  {
    switch item.action {

      case #selector(showInFinder(_:)),
           #selector(copyFileName(_:)):
        return selectedChange != nil

      case #selector(open(_:)):
        guard let change = selectedChange
        else { return false }
        guard let openMenuItem = item as? NSMenuItem
        else { return true }

        openMenuItem.submenu = nil

        let fileExtension = change.path.pathExtension
        guard let type = UTType(filenameExtension: fileExtension)
        else { return false }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        let items = urls.map {
          let appName = $0.lastPathComponent.deletingPathExtension
          let item = NSMenuItem(title: appName,
                                action: #selector(self.openInApp(_:)),
                                keyEquivalent: "")
          item.representedObject = $0
          return item
        }
        guard !items.isEmpty
        else { return false }
        let menu = NSMenu(title: "Open")

        menu.items = items
        openMenuItem.submenu = menu
        return true

      case #selector(self.openInApp(_:)):
        return true

      default:
        return false
    }
  }
}

// MARK: NSOutlineViewDelegate
extension FileListController: NSOutlineViewDelegate
{
  func outlineView(_ outlineView: NSOutlineView,
                   viewFor tableColumn: NSTableColumn?, item: Any) -> NSView?
  {
    guard let columnID = tableColumn?.identifier
    else { return nil }
    let change = viewDataSource.change(for: item)
    
    switch columnID {
      case ColumnID.action:
        guard change != .unmodified,
              let cell = outlineView.makeView(withIdentifier: CellViewID.action,
                                              owner: self) as? TableButtonView,
              let button = cell.button as? RolloverButton
        else { break }
      
        button.rolloverImage = actionImage
        button.alternateImage = pressedImage
        button.target = self
        button.action = actionButtonSelector
        return cell
      
      case ColumnID.file:
        guard let cell = outlineView.makeView(withIdentifier: CellViewID.fileCell,
                                              owner: self) as? FileCellView
        else { break }
        let path = viewDataSource.path(for: item)
        let isFolder: Bool
        let name: String

        if path.hasSuffix("/") {
          isFolder = true
          name = path.pathComponents.dropLast().last ?? ""
        }
        else if viewDataSource.outlineView!(outlineView, isItemExpandable: item) {
          isFolder = true
          name = path.lastPathComponent
        }
        else {
          isFolder = false
          name = path.lastPathComponent
        }

        cell.textField?.stringValue = name
        cell.imageView?.image = isFolder
            ? NSImage(named: NSImage.folderName)
            : NSWorkspace.shared.icon(for: .fromExtension(path.pathExtension))
        
        cell.textField?.textColor = textColor(for: change,
                                              outlineView: outlineView,
                                              item: item)
        cell.change = change
        
        if let image = change.changeImage {
          cell.statusImage.image = image
          cell.statusImage.isHidden = false
        }
        else {
          cell.statusImage.isHidden = true
        }
        return cell

      default:
        break
    }
    return nil
  }
  
  func outlineViewSelectionDidChange(_ notification: Notification)
  {
    updateButtons()
  }
  
  private func textColor(for change: DeltaStatus, outlineView: NSOutlineView,
                         item: Any)
    -> NSColor
  {
    if change == .deleted {
      return NSColor.disabledControlTextColor
    }
    else if outlineView.isRowSelected(outlineView.row(forItem: item)) {
      return NSColor.selectedTextColor
    }
    else {
      return NSColor.textColor
    }
  }
}

private extension FileChangeNode
{
  /// Every leaf (file) change at or under this node: a file node yields
  /// its own change; a folder yields all file changes in its sub-tree.
  var leafChanges: [FileChange]
  {
    isLeaf ? [value] : children.flatMap { $0.leafChanges }
  }
}

extension DeltaStatus
{
  var changeImage: NSImage?
  {
    let info: (String, NSColor)

    switch self {
      case .added, .untracked:
        info = ("plus.circle", .systemGreen)
      case .copied:
        info = ("circlebadge.2.fill", .systemGreen)
      case .deleted:
        info = ("minus.circle", .systemRed)
      case .modified, .typeChange:
        info = ("pencil.circle", .systemBlue)
      case .renamed:
        info = ("r.circle", .systemTeal)
      case .conflict:
        info = ("exclamationmark.triangle.fill", .systemYellow)
      case .mixed:
        info = ("ellipsis.circle.fill", .systemGray)
      default:
        return nil
    }
    return NSImage(systemSymbolName: info.0)!
      .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))!
      .image(coloredWith: info.1)
  }
}
