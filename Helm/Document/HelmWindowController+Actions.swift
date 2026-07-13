import AppKit

extension HelmWindowController
{
  @IBAction
  func refresh(_ sender: AnyObject)
  {
    refreshWithFetch()
  }
  
  @IBAction
  func newTag(_: AnyObject)
  {
    _ = startOperation { NewTagOpController(windowController: self) }
  }
  
  @IBAction
  func newBranch(_: AnyObject)
  {
    _ = startOperation { NewBranchOpController(windowController: self) }
  }
  
  @IBAction
  func newRemote(_: AnyObject)
  {
    _ = startOperation { NewRemoteOpController(windowController: self) }
  }

  @IBAction
  func goBack(_: AnyObject)
  {
    withNavigating {
      selection.map { navForwardStack.append($0) }
      selection = navBackStack.popLast()
    }
  }
  
  @IBAction
  func goForward(_: AnyObject)
  {
    withNavigating {
      selection.map { navBackStack.append($0) }
      selection = navForwardStack.popLast()
    }
  }

  @IBAction
  func fetch(_: AnyObject)
  {
    let _: FetchOpController? = startOperation()
  }

  @IBAction
  func fetchAllRemotes(_: AnyObject)
  {
    startOperation {
      FetchOpController(remoteOption: .all, windowController: self)
    }
  }

  @IBAction
  func fetchCurrentBranch(_: AnyObject)
  {
    startOperation {
      FetchOpController(remoteOption: .currentBranch, windowController: self)
    }
  }

  @IBAction
  func updateSubmodules(_: AnyObject)
  {
    guard !repoController.queue.isBusy
    else { return }

    let submodules = repository.submodules()
    guard !submodules.isEmpty
    else { return }

    repoController.queue.executeOffMainThread {
      for submodule in submodules {
        let callbacks = self.remoteCallbacks(for: submodule.url)

        do {
          try submodule.update(callbacks: callbacks)
        }
        catch {
          repoLogger.debug(
              "Submodule update failed for \(submodule.name): \(error)")
        }
      }

      Task { @MainActor in
        self.refreshLocalState()
        self.repoController.indexChanged()
      }
    }
  }

  @IBAction
  func fetchRemote(_ sender: NSMenuItem)
  {
    let index = sender.tag
    let remotes = repository.remoteNames()
    guard (0..<remotes.count).contains(index)
    else { return }

    startOperation {
      FetchOpController(remoteOption: .named(remotes[index]),
                        windowController: self)
    }
  }

  @IBAction
  func pull(_: AnyObject)
  {
    let _: PullOpController? = startOperation()
  }

  @IBAction
  func pullCurrentBranch(_ sender: AnyObject)
  {
    pull(sender)
  }

  @IBAction
  func push(_: AnyObject)
  {
    let _: PushOpController? = startOperation()
  }

  @IBAction
  func pushToRemote(_ sender: NSMenuItem)
  {
    let index = sender.tag
    let remotes = repository.remoteNames()
    guard (0..<remotes.count).contains(index)
    else { return }

    startOperation {
      PushOpController(remoteOption: .named(remotes[index]),
                       windowController: self)
    }
  }

  @IBAction
  func pullRemote(_ sender: NSMenuItem)
  {
    let index = sender.tag
    let remotes = repository.remoteNames()
    guard (0..<remotes.count).contains(index)
    else { return }

    startOperation {
      PullOpController(remoteName: remotes[index],
                       windowController: self)
    }
  }

  @IBAction
  func stash(_: AnyObject)
  {
    let _: StashOperationController? = startOperation()
  }
  
  func tryRepoOperation(_ operation: @escaping () throws -> Void)
  {
    repoController.queue.executeOffMainThread {
      [weak self] in
      do {
        try operation()
        Task { @MainActor in
          self?.repoController.indexChanged()
          self?.repoController.refsChanged()
        }
      }
      catch let error as RepoError {
        Task { @MainActor in
          self?.showErrorMessage(error: error)
          self?.repoController.indexChanged()
          self?.repoController.refsChanged()
        }
      }
      catch {
        Task { @MainActor in
          self?.showErrorMessage(error: .unexpected)
          self?.repoController.indexChanged()
          self?.repoController.refsChanged()
        }
      }
    }
  }
  
  func noStashesAlert()
  {
    let alert = NSAlert()
    
    alert.messageString = .noStashes
    alert.beginSheetModal(for: window!)
  }

  func firstStash<R>(_ repo: R) -> (any Stash)? where R: Stashing
  {
    repo.stashes.first
  }

  @IBAction
  func popStash(_: AnyObject)
  {
    guard let stash = firstStash(repository)
    else {
      noStashesAlert()
      return
    }
    
    NSAlert.confirm(message: .confirmPop,
                    infoString: stash.message.map { UIString(rawValue: $0) },
                    actionName: .pop, parentWindow: window!) {
      self.tryRepoOperation() {
        try self.repository.popStash(index: 0)
      }
    }
  }
  
  @IBAction
  func applyStash(_: AnyObject)
  {
    guard let stash = firstStash(repository)
    else {
      noStashesAlert()
      return
    }

    NSAlert.confirm(message: .confirmApply,
                    infoString: stash.message.map { UIString(rawValue: $0) },
                    actionName: .apply, parentWindow: window!) {
      self.tryRepoOperation() {
        try self.repository.applyStash(index: 0)
      }
    }
  }
  
  @IBAction
  func dropStash(_: AnyObject)
  {
    guard let stash = firstStash(repository)
    else {
      noStashesAlert()
      return
    }

    NSAlert.confirm(message: .confirmStashDelete,
                    infoString: stash.message.map { UIString(rawValue: $0) },
                    actionName: .drop, isDestructive: true,
                    parentWindow: window!) {
      self.tryRepoOperation() {
        try self.repository.dropStash(index: 0)
      }
    }
  }

  @IBAction
  func clean(_ sender: AnyObject)
  {
    startOperation { CleanOpController(windowController: self) }
  }

  @IBAction
  func remoteSettings(_ sender: AnyObject)
  {
    guard let menuItem = sender as? NSMenuItem
    else { return }
    
    remoteSettings(remote: menuItem.title)
  }
  
  func remoteSettings(remote: String)
  {
    startOperation {
      RemoteOptionsOpController(windowController: self, remote: remote)
    }
  }
}

// MARK: Action helpers
extension HelmWindowController
{
  fileprivate func withNavigating(_ callback: () -> Void)
  {
    navigating = true
    callback()
    navigating = false
    updateNavButtons()
  }
}

extension HelmWindowController: NSMenuItemValidation
{
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
  {
    guard let action = menuItem.action
    else { return false }
    let result: Bool
    
    switch action {
      
      case #selector(self.goBack(_:)):
        result = !navBackStack.isEmpty

      case #selector(self.goForward(_:)):
        result = !navForwardStack.isEmpty

      case #selector(self.refresh(_:)):
        result = !repoDocument!.repository.isWriting

      case #selector(self.remoteSettings(_:)):
        result = true

      case #selector(self.stash(_:)):
        result = true

      case #selector(self.newBranch(_:)),
           #selector(self.newTag(_:)),
           #selector(self.newRemote(_:)):
        result = true

      case #selector(self.runDefaultAction(_:)),
           #selector(self.runCustomAction(_:)),
           #selector(self.configureActions(_:)):
        result = true

      case #selector(self.performFindPanelAction(_:)):
        guard let action = NSFindPanelAction(rawValue: UInt(menuItem.tag))
        else { return false }
        switch action {
          case .showFindPanel:
            result = titleBarController?.canShowSearch ?? false
          case .next, .previous:
            result = titleBarController?.canNavigateSearch ?? false
          case .setFindString:
            result = titleBarController?.canShowSearch == true
              && selectedFindString() != nil
          default:
            result = false
        }

      case #selector(self.pull(_:)),
           #selector(self.pullCurrentBranch(_:)):
        if let (branchName, remote) = trackingBranchInfo() {
          menuItem.titleString = .pullCurrent(branch: branchName,
                                              remote: remote)
          result = true
        }
        else {
          menuItem.titleString = .pullCurrentUnavailable
          result = false
        }

      case #selector(self.fetchAllRemotes(_:)):
        result = !repository.remoteNames().isEmpty

      case #selector(self.updateSubmodules(_:)):
        result = !repoController.queue.isBusy && !repository.submodules().isEmpty

      case #selector(self.fetchCurrentBranch(_:)):
        if let (branchName, remote) = trackingBranchInfo() {
          menuItem.titleString = .fetchCurrent(branch: branchName,
                                               remote: remote)
          result = true
        }
        else {
          menuItem.titleString = .fetchCurrentUnavailable
          result = false
        }

      case #selector(self.fetchRemote(_:)),
           #selector(self.pushToRemote(_:)),
           #selector(self.pullRemote(_:)):
        result = true

      case #selector(self.push(_:)):
        if let (branchName, remote) = trackingBranchInfo() {
          menuItem.titleString = .pushCurrent(branch: branchName,
                                              remote: remote)
          result = true
        }
        else if repository.remotes().isEmpty {
          menuItem.titleString = .pushCurrentUnavailable
          result = false
        }
        else {
          menuItem.titleString = .pushNew
          result = true
        }

      default:
        result = false
    }
    return result
  }

  func trackingBranchInfo() -> (String, String)?
  {
    if let branchName = repository.currentBranch,
       let branch = repository.localBranch(named: branchName),
       let trackingBranch = branch.trackingBranch,
       let remote = trackingBranch.remoteName {
      return (branchName.name, remote)
    }
    else {
      return nil
    }
  }
}
