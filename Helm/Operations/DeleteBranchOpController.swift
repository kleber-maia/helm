import Cocoa

final class DeleteBranchOpController: PasswordOpController
{
  let branch: LocalBranchRefName

  init(branch: LocalBranchRefName, windowController: HelmWindowController)
  {
    self.branch = branch
    super.init(windowController: windowController)
  }

  required init(windowController: HelmWindowController)
  {
    fatalError("init(windowController:) has not been implemented")
  }

  override func start() throws
  {
    guard let repository = repository
    else { throw RepoError.unexpected }

    try start(repository)
  }

  func start<R>(_ repository: R) throws where R: FullRepository
  {
    guard let localBranch = repository.localBranch(named: branch),
          let trackingBranch = localBranch.trackingBranch,
          let remoteName = trackingBranch.remoteName,
          let remote = repository.remote(named: remoteName)
    else {
      throw RepoError.unexpected
    }

    let alert = NSAlert()

    alert.messageString = .confirmDeleteBranchAndRemote(
        branch: branch.name, remote: remoteName)
    alert.informativeString = .deleteBranchAndRemoteInfo
    alert.addButton(withString: .delete)
    alert.addButton(withString: .cancel)
    alert.buttons[0].hasDestructiveAction = true
    alert.buttons[0].keyEquivalent = ""

    alert.beginSheetModal(for: windowController!.window!) {
      (response) in
      if response == .alertFirstButtonReturn {
        self.deleteBranchAndRemote(repository: repository,
                                   localBranch: localBranch,
                                   remote: remote)
      }
      else {
        self.ended(result: .canceled)
      }
    }
  }

  func deleteBranchAndRemote<R>(repository: R,
                                localBranch: R.LocalBranch,
                                remote: R.Remote)
    where R: RemoteManagement & Branching
  {
    if let url = remote.pushURL ?? remote.url {
      self.setKeychainInfo(from: url)
    }

    tryRepoOperation {
      try repository.deleteBranch(localBranch.referenceName)

      guard let trackingBranch = localBranch.trackingBranch
      else {
        self.refsChangedAndEnded()
        return
      }

      let callbacks = RemoteCallbacks(passwordBlock: self.getPassword,
                                      downloadProgress: nil,
                                      uploadProgress: nil)

      try repository.deleteRemoteBranch(named: trackingBranch.referenceName,
                                        remote: remote,
                                        callbacks: callbacks)
      self.refsChangedAndEnded()
    }
  }

  override func shoudReport(error: NSError) -> Bool
  {
    return true
  }
}
