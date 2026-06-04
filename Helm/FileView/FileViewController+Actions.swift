import Cocoa

// MARK: NSUserInterfaceValidations
extension FileViewController: NSUserInterfaceValidations
{
  func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
  {
    guard let action = item.action
    else { return false }
    
    switch action {

      case #selector(self.stageAll(_:)):
        guard let selection = repoUIController?.selection as? StagingSelection
        else { return false }
        
        return !selection.workspaceFileList.changes.isEmpty
      
      case #selector(self.unstageAll(_:)):
        guard let selection = repoUIController?.selection as? StagingSelection
        else { return false }
        
        return !selection.indexFileList.changes.isEmpty
      
      case #selector(self.showWhitespaceChanges(_:)):
        return validateWhitespaceMenuItem(item, whitespace: .showAll)
      case #selector(self.ignoreEOLWhitespace(_:)):
        return validateWhitespaceMenuItem(item, whitespace: .ignoreEOL)
      case #selector(self.ignoreAllWhitespace(_:)):
        return validateWhitespaceMenuItem(item, whitespace: .ignoreAll)
        
      case #selector(self.tabWidth2(_:)):
        return validateTabMenuItem(item, width: 2)
      case #selector(self.tabWidth4(_:)):
        return validateTabMenuItem(item, width: 4)
      case #selector(self.tabWidth6(_:)):
        return validateTabMenuItem(item, width: 6)
      case #selector(self.tabWidth8(_:)):
        return validateTabMenuItem(item, width: 8)
        
      case #selector(self.context0(_:)):
        return validateContextLinesMenuItem(item, context: 0)
      case #selector(self.context3(_:)):
        return validateContextLinesMenuItem(item, context: 3)
      case #selector(self.context6(_:)):
        return validateContextLinesMenuItem(item, context: 6)
      case #selector(self.context12(_:)):
        return validateContextLinesMenuItem(item, context: 12)
      case #selector(self.context25(_:)):
        return validateContextLinesMenuItem(item, context: 25)
      
      case #selector(self.wrapToWidth(_:)):
        return validateWrappingMenuItem(item, wrapping: .windowWidth)
      case #selector(self.wrapTo80(_:)):
        return validateWrappingMenuItem(item, wrapping: .columns(80))
      case #selector(self.noWrapping(_:)):
        return validateWrappingMenuItem(item, wrapping: .none)
      
      case #selector(self.themeSelected(_:)):
        if let menuItem = item as? NSMenuItem {
          return validateThemeMenuItem(menuItem)
        }
        return true

      default:
        return true
    }
  }
}

// MARK: Validation
extension FileViewController
{
  func validateWhitespaceMenuItem(_ item: AnyObject,
                                  whitespace: WhitespaceSetting) -> Bool
  {
    let menuItem = item as? NSMenuItem
    guard let wsController = contentController as? WhitespaceVariable
    else {
      menuItem?.state = .off
      return false
    }
    
    menuItem?.state = (wsController.whitespace == whitespace) ? .on : .off
    return true
  }
  
  func validateTabMenuItem(_ item: AnyObject, width: UInt) -> Bool
  {
    let menuItem = item as? NSMenuItem
    guard let tabController = contentController as? TabWidthVariable
    else {
      menuItem?.state = .off
      return false
    }
    
    menuItem?.state = (tabController.tabWidth == width) ? .on : .off
    return true
  }
  
  func validateContextLinesMenuItem(_ item: AnyObject, context: UInt) -> Bool
  {
    let menuItem = item as? NSMenuItem
    guard let contextController = contentController as? ContextVariable
    else {
      menuItem?.state = .off
      return false
    }
    
    menuItem?.state = (contextController.contextLines == context) ? .on : .off
    return true
  }
  
  func validateWrappingMenuItem(_ item: AnyObject, wrapping: TextWrapping) -> Bool
  {
    let menuItem = item as? NSMenuItem
    guard let wrappingController = contentController as? WrappingVariable
    else {
      menuItem?.state = .off
      return false
    }
    
    menuItem?.state = (wrappingController.wrapping == wrapping) ? .on : .off
    return true
  }
}

// MARK: Actions
extension FileViewController
{
  @IBAction
  func changeContentView(_ sender: Any?)
  {
    guard let segmentedControl = sender as? NSSegmentedControl
    else { return }

    diffController.mode = segmentedControl.selectedSegment == 0
        ? .diff : .text
    diffController.reloadCurrentSelection()
  }

  @IBAction
  func refreshStaging(_: Any?)
  {
    repoController?.invalidateIndex()
    reviewListController.stagingDataSource.reload()
  }

  @IBAction
  func stage(_: Any?)
  {
  }

  @IBAction
  func unstage(_: Any?)
  {
  }

  @IBAction
  func revert(_: Any?)
  {
  }

  @IBAction
  func stageAll(_: Any?)
  {
    performRepositoryMutation {
      try self.repo?.stageAllFiles()
    } onSuccess: {
      self.showingStaged = true
    }
  }
  
  @IBAction
  func unstageAll(_: Any?)
  {
    performRepositoryMutation {
      try self.repo?.unstageAllFiles()
    } onSuccess: {
      self.showingStaged = false
    }
  }

  @IBAction
  func showWhitespaceChanges(_ sender: Any?)
  {
    setWhitespace(.showAll)
  }
  
  @IBAction
  func ignoreEOLWhitespace(_ sender: Any?)
  {
    setWhitespace(.ignoreEOL)
  }
  
  @IBAction
  func ignoreAllWhitespace(_ sender: Any?)
  {
    setWhitespace(.ignoreAll)
  }
  
  @IBAction
  func tabWidth2(_ sender: Any?)
  {
    setTabWidth(2)
  }
  
  @IBAction
  func tabWidth4(_ sender: Any?)
  {
    setTabWidth(4)
  }
  
  @IBAction
  func tabWidth6(_ sender: Any?)
  {
    setTabWidth(6)
  }
  
  @IBAction
  func tabWidth8(_ sender: Any?)
  {
    setTabWidth(8)
  }
  
  @IBAction
  func context0(_ sender: Any?)
  {
    setContext(0)
  }
  
  @IBAction
  func context3(_ sender: Any?)
  {
    setContext(3)
  }
  
  @IBAction
  func context6(_ sender: Any?)
  {
    setContext(6)
  }
  
  @IBAction
  func context12(_ sender: Any?)
  {
    setContext(12)
  }
  
  @IBAction
  func context25(_ sender: Any?)
  {
    setContext(25)
  }
  
  @IBAction
  func wrapToWidth(_ sender: Any?)
  {
    setWrapping(.windowWidth)
  }
  
  @IBAction
  func wrapTo80(_ sender: Any?)
  {
    setWrapping(.columns(80))
  }
  
  @IBAction
  func noWrapping(_ sender: Any?)
  {
    setWrapping(.none)
  }
  
  func setWhitespace(_ setting: WhitespaceSetting)
  {
    (contentController as? WhitespaceVariable)?.whitespace = setting
  }
  
  func setTabWidth(_ tabWidth: UInt)
  {
    (contentController as? TabWidthVariable)?.tabWidth = tabWidth
  }
  
  func setContext(_ context: UInt)
  {
    (contentController as? ContextVariable)?.contextLines = context
  }
  
  func setWrapping(_ wrapping: TextWrapping)
  {
    (contentController as? WrappingVariable)?.wrapping = wrapping
  }
}

// MARK: HunkStaging
extension FileViewController: HunkStaging
{
  func patchIndexFile(hunk: any DiffHunk, stage: Bool)
  {
    guard let selectedChange = self.selectedChange
      else { return }
    let path = selectedChange.gitPath
    
    performRepositoryMutation {
      try self.repo?.patchIndexFile(path: path, hunk: hunk, stage: stage)
    }
  }
  
  func stage(hunk: any DiffHunk)
  {
    patchIndexFile(hunk: hunk, stage: true)
  }
  
  func unstage(hunk: any DiffHunk)
  {
    patchIndexFile(hunk: hunk, stage: false)
  }
  
  func discard(hunk: any DiffHunk)
  {
    var encoding = String.Encoding.utf8
    
    guard let controller = repoUIController,
      let selection = controller.selection as? StagingSelection,
      let selectedChange = self.selectedChange,
      let fileURL = selection.unstagedFileList.fileURL(selectedChange.gitPath)
      else {
        repoLogger.debug("Setup for discard hunk failed")
        return
    }
    
    do {
      let status = try repo!.status(file: selectedChange.gitPath)
      
      if ((hunk.newStart == 1) && (status.0 == .untracked)) ||
        ((hunk.oldStart == 1) && (status.0 == .deleted)) {
        revert(path: selectedChange.gitPath)
      }
      else {
        let fileText = try String(contentsOf: fileURL, usedEncoding: &encoding)
        guard let result = hunk.applied(to: fileText, reversed: true)
          else {
            throw RepoError.patchMismatch
        }
        
        try result.write(to: fileURL, atomically: true, encoding: encoding)
      }
    }
    catch let error as RepoError {
      displayRepositoryAlert(error: error)
    }
    catch let error as NSError {
      displayAlert(error: error)
    }
  }
}

private extension FileViewController
{
  func performRepositoryMutation(
      _ mutation: @escaping () throws -> Void,
      onSuccess: (@MainActor () -> Void)? = nil)
  {
    guard let queue = repoController?.queue
    else { return }

    queue.executeOffMainThread {
      [weak self] in
      do {
        try mutation()
        Task { @MainActor in
          self?.repoController?.indexChanged()
          onSuccess?()
        }
      }
      catch let error as RepoError {
        Task { @MainActor in
          self?.displayRepositoryAlert(error: error)
          self?.repoController?.indexChanged()
        }
      }
      catch let error as NSError {
        Task { @MainActor in
          self?.displayAlert(error: error)
          self?.repoController?.indexChanged()
        }
      }
    }
  }
}
