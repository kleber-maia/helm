import Cocoa

final class PullOpController: FetchOpController
{
  let remoteName: String?

  init(remoteName: String, windowController: HelmWindowController)
  {
    self.remoteName = remoteName

    super.init(windowController: windowController)
  }

  required init(windowController: HelmWindowController)
  {
    self.remoteName = nil

    super.init(windowController: windowController)
  }

  override func start() throws
  {
    guard let repository = repository,
          let branchName = repository.currentBranch
    else {
      repoLogger.debug("Can't get current branch")
      throw RepoError.detachedHead
    }

    try start(repository, branchName)
  }

  func start(_ repository: some RemoteManagement & Branching,
             _ branchName: LocalBranchRefName) throws
  {
    guard let branch = repository.localBranch(named: branchName),
          let remoteBranch = branch.trackingBranch,
          let trackingRemoteName = remoteBranch.remoteName
    else {
      repoLogger.debug("Can't pull - no tracking branch")
      throw RepoError.unexpected
    }

    let pullRemoteName = remoteName ?? trackingRemoteName

    guard pullRemoteName == trackingRemoteName,
          let remote = repository.remote(named: pullRemoteName)
    else {
      repoLogger.debug("Can't pull - selected remote is not the tracking remote")
      throw RepoError.notFound
    }
    
    tryRepoOperation {
      let callbacks = RemoteCallbacks(passwordBlock: self.getPassword,
                                      downloadProgress: self.progressCallback,
                                      uploadProgress: nil)
      let options = FetchOptions(downloadTags: true,
                                 pruneBranches: true,
                                 callbacks: callbacks)
      
      try repository.pull(branch: branch, remote: remote, options: options)
      self.refsChangedAndEnded()
    }
  }
}
