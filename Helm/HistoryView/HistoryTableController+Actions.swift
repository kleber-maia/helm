import Cocoa

extension HistoryTableController: NSMenuItemValidation
{
  public func validateMenuItem(_ item: NSMenuItem) -> Bool
  {
    switch item.action {

      case #selector(copySHA(sender:)):
        return true

      case #selector(resetToCommit(sender:)):
        if let (clickedRow, _) = tableView.contextMenuCell,
           clickedRow >= 0,
           let branchName = repository.currentBranch,
           let branch = repository.localBranch(named: branchName),
           let branchOID = branch.oid {
          return branchOID != history.entries[clickedRow].commit.id
        }
        else {
          return false
        }

      default:
        return false
    }
  }
}

extension HistoryTableController
{
  @IBAction func copySHA(sender: Any?)
  {
    guard let clickedCell = tableView.contextMenuCell
    else { return }
    let pasteboard = NSPasteboard.general

    pasteboard.clearContents()
    pasteboard.setString(history.entries[clickedCell.0].commit.id.sha.rawValue,
                         forType: .string)
  }

  @IBAction func resetToCommit(sender: Any?)
  {
    guard let clickedCell = tableView.contextMenuCell,
          let windowController = view.window?.windowController
                                 as? HelmWindowController
    else { return }

    windowController.startOperation {
      ResetOpController(windowController: windowController,
                        targetCommit: history.entries[clickedCell.0].commit)
    }
  }
}
