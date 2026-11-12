import AppKit

class RepoDocument: NSDocument
{
  private(set) var repository: HelmRepository! = nil
  var sessionID = UUID()
  var terminalDirectoryURL: URL?
  var worktreeBinding: WorktreeBinding?
  var worktreeRemovalPending = false
  var closeDecisionPending = false
  var closeApproved = false
  var windowController: HelmWindowController? {
    windowControllers.first as? HelmWindowController
  }

  // Don't allow creating an untitled document
  convenience init(type typeName: String) throws
  {
    throw NSError(osStatus: -1)
  }

  override func makeWindowControllers()
  {
    let storyboard = NSStoryboard(name: "HelmWindowController", bundle: nil)

    if let controller = storyboard.instantiateInitialController()
        as? HelmWindowController {
      addWindowController(controller)
      controller.finalizeSetup()
    }
  }

  override func read(from url: URL, ofType typeName: String) throws
  {
    // NSDocument.read(from:ofType:) is nonisolated, but in practice it gets
    // called on the main thread
    try MainActor.assumeIsolated {
      let gitURL = url.appendingPathComponent(".git")

      if !FileManager.default.fileExists(atPath: gitURL.path) {
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileReadUnknownError,
                      userInfo: [NSLocalizedFailureReasonErrorKey:
                                  "The folder does not contain a Git repository."])
      }

      guard let repository = HelmRepository(url: url)
      else {
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileReadNoSuchFileError)
      }

      self.repository = repository
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
      (NSApp.delegate as? AppDelegate)?.dismissOpenPanel()
    }
  }

  override func canClose(withDelegate delegate: Any,
                         shouldClose shouldCloseSelector: Selector?,
                         contextInfo: UnsafeMutableRawPointer?)
  {
    if worktreeRemovalPending {
      HelmReplyToDocumentClose(delegate as AnyObject, shouldCloseSelector,
                               self, false, contextInfo)
      return
    }
    let controller = windowController
    closeApproved = true
    controller?.terminalPanelController?.suspendAutomaticStart()
    controller?.shutDown()

    super.canClose(withDelegate: delegate,
                   shouldClose: shouldCloseSelector,
                   contextInfo: contextInfo)
  }

  override func close()
  {
    closeApproved = true
    windowController?.terminalPanelController?.suspendAutomaticStart()
    (NSDocumentController.shared as? HelmDocumentController)?
      .sessions.willClose(self)
    windowController?.shutDown()
    windowController?.terminalPanelController?.terminalController.stopIfRunning()
    super.close()
  }

  override func updateChangeCount(_ change: NSDocument.ChangeType)
  {
    // Do nothing. There is no need for an "unsaved" state.
  }
}
