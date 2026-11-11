import Cocoa

final class HelmDocumentController: NSDocumentController
{
  lazy var sessions = RepositorySessionController(documents: self)
  lazy var worktrees = WorktreeWorkspaceController(documents: self)

  // A repository URL identifies the data, not a document/terminal session.
  override func openDocument(
      withContentsOf url: URL, display displayDocument: Bool,
      completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void)
  {
    do {
      let (document, alreadyOpen) = try worktrees.open(at: url, display: displayDocument)
      sessions.scheduleSave()
      completionHandler(document, alreadyOpen, nil)
    }
    catch { completionHandler(nil, false, error) }
  }

  func openRepository(at url: URL, id: UUID, tabbingWith anchor: NSWindow?,
                      display: Bool, terminalDirectory: URL? = nil,
                      binding: WorktreeBinding? = nil)
      throws -> RepoDocument
  {
    let type = try typeForContents(of: url)
    let document = try RepoDocument(contentsOf: url, ofType: type)
    document.sessionID = id
    document.worktreeBinding = binding
    document.terminalDirectoryURL = terminalDirectory
    addDocument(document)
    NSFileCoordinator.addFilePresenter(document)
    if display {
      document.makeWindowControllers()
      if let window = document.windowControllers.first?.window {
        // Explicit grouping also keeps separately restored windows separate.
        window.isRestorable = false
        if let binding { window.tabbingIdentifier = binding.record.repositoryID }
        window.tabbingMode = .disallowed
        anchor?.addTabbedWindow(window, ordered: .above)
        document.showWindows()
        window.tabbingMode = .automatic
        window.makeKeyAndOrderFront(nil)
      }
    }
    return document
  }

  func prepareForTermination() -> Bool
  {
    guard !worktrees.isTerminating else { return true }
    worktrees.isConfirmingTermination = true
    defer { worktrees.isConfirmingTermination = false }
    let active = documents.compactMap { $0 as? RepoDocument }.contains {
      $0.windowController?.terminalIsRunning == true ||
      $0.windowController?.currentOperation != nil ||
      $0.windowController?.repoController?.queue.isBusy == true
    }
    if active {
      let alert = NSAlert()
      alert.messageText = "Quit Helm and stop running sessions?"
      alert.informativeText = "Open tabs will be restored next launch. Running terminals and Git operations cannot continue after quitting."
      alert.addButton(withTitle: "Keep Helm Open")
      alert.addButton(withTitle: "Quit and Stop Sessions")
      guard alert.runModal() == .alertSecondButtonReturn else {
        worktrees.isConfirmingTermination = false
        for document in documents.compactMap({ $0 as? RepoDocument }) {
          worktrees.retryPending(document)
        }
        return false
      }
    }
    sessions.prepareForTermination()
    worktrees.isTerminating = true
    return true
  }

  func cancelTerminationPreparation()
  {
    worktrees.isTerminating = false
    sessions.cancelTerminationPreparation()
    for document in documents.compactMap({ $0 as? RepoDocument }) {
      worktrees.retryPending(document)
    }
  }

  // This can get triggered by clicking the new tab button in a tabbed window.
  override func newDocument(_ sender: Any?)
  {
    _ = NSApp.delegate?.perform(#selector(openDocument(_:)), with: sender)
  }


  override func openUntitledDocumentAndDisplay(_ displayDocument: Bool) throws
    -> NSDocument
  {
    throw NSError(domain: NSCocoaErrorDomain,
                  code: CocoaError.featureUnsupported.rawValue)
  }

  override func makeUntitledDocument(ofType typeName: String) throws
    -> NSDocument {
    throw NSError(domain: NSCocoaErrorDomain,
                  code: CocoaError.featureUnsupported.rawValue)
  }

  override func makeDocument(withContentsOf url: URL,
                             ofType typeName: String) throws -> NSDocument
  {
    try RepoDocument(contentsOf: url, ofType: typeName)
  }

  override func makeDocument(for urlOrNil: URL?,
                             withContentsOf contentsURL: URL,
                             ofType typeName: String) throws -> NSDocument
  {
    try RepoDocument(contentsOf: contentsURL, ofType: typeName)
  }
}
