import Cocoa

final class StagedFileListController: StagingFileListController
{
  override var actionImage: NSImage?
  { .xtUnstageButtonHover }
  override var pressedImage: NSImage?
  { .xtUnstageButtonPressed }
  override var actionButtonSelector: Selector?
  { #selector(self.unstage(_:)) }
  
  override func loadView()
  {
    super.loadView()
    
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(.FileList.Staged.group)
    view.setAccessibilityRole(.group)
    outlineView.setAccessibilityIdentifier(.FileList.Staged.list)

    listTypeIcon.image = .xtStaged
    listTypeLabel.uiStringValue = .staged
    
    addModifyingToolbarButton(image: .xtUnstageAll,
                              toolTip: .unstageAll,
                              action: #selector(unstageAll(_:)))
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
  
  func reloadFileList()
  {
    (outlineView.dataSource as? FileListDataSource)?.reload()
  }
}

// NSUserInterfaceValidations
extension StagedFileListController
{
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem)
    -> Bool
  {
    let menuItem = item as? NSMenuItem
    
    switch item.action {
      case #selector(stageAll(_:)),
           #selector(revert(_:)),
           #selector(showIgnored(_:)):
        menuItem?.isHidden = true
        return false
      case #selector(unstage(_:)):
        menuItem?.isHidden = !canModify
        return selectedChange != nil
      case #selector(unstageAll(_:)):
        menuItem?.isHidden = !canModify
        return outlineView.numberOfRows != 0
      default:
        return super.validateUserInterfaceItem(item)
    }
  }
}
