import Cocoa

final class NewBranchOpController: OperationController
{
  override func start() throws
  {
    guard let repository = repository
    else { throw RepoError.unexpected }
    
    let panel = NewBranchPanelController.controller()
    
    panel.configure(branchName: "",
                    startingPoint: repository.currentBranch?.name ?? "",
                    repository: repository)
    windowController!.window!.beginSheet(panel.window!) {
      (response) in
      if response == NSApplication.ModalResponse.OK {
        self.executeBranch(name: panel.branchName,
                           startPoint: panel.startingPoint,
                           track: panel.trackStartingPoint,
                           checkOut: panel.checkOutBranch)
      }
      else {
        self.ended(result: .canceled)
      }
    }
  }
  
  func executeBranch(name: String, startPoint: String,
                     track: Bool, checkOut: Bool)
  {
    guard let repository
    else {
      fail(with: .unexpected)
      return
    }

    tryRepoOperation {
      let operation = NewBranchOperation(
            repository: repository)
      let parameters = NewBranchOperation.Parameters(
            name: name, startPoint: startPoint,
            track: track, checkOut: checkOut)

      try operation.perform(using: parameters)
      self.refsChangedAndEnded()
    }
  }
}
