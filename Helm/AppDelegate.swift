import AppKit

@objc(HelmApplication)
final class HelmApplication: NSApplication
{
  private var closingForTermination = false

  override func terminate(_ sender: Any?)
  {
    guard !closingForTermination else { return }
    guard let documents = NSDocumentController.shared as? HelmDocumentController
    else {
      super.terminate(sender)
      return
    }
    guard documents.prepareForTermination() else { return }

    closingForTermination = true
    (delegate as? AppDelegate)?.cancelOpenPanelForTermination()
    repoLogger.publicInfo("termination approved; closing documents")
    documents.closeAllDocuments(withDelegate: self,
        didCloseAllSelector: #selector(didCloseDocumentsForTermination(_:didCloseAll:contextInfo:)),
        contextInfo: nil)
  }

  @objc private func didCloseDocumentsForTermination(
      _ documents: NSDocumentController, didCloseAll: Bool,
      contextInfo: UnsafeMutableRawPointer?)
  {
    repoLogger.publicInfo("termination documents closed=\(didCloseAll)")
    guard didCloseAll else {
      closingForTermination = false
      (documents as? HelmDocumentController)?.cancelTerminationPreparation()
      return
    }
    // Let the confirmation's modal event unwind before requesting AppKit's
    // final termination. Keep approval/session capture until actual completion.
    DispatchQueue.main.async { [weak self] in
      self?.finishTerminationAfterClosingDocuments()
    }
  }

  private func finishTerminationAfterClosingDocuments()
  {
    repoLogger.publicInfo("termination passing control to AppKit")
    super.terminate(nil)
  }
}

@NSApplicationMain @MainActor
final class AppDelegate: NSObject
{
  var openPanel: NSOpenPanel?

  @IBOutlet var remoteSettingsSubmenu: NSMenu!
  
  @IBAction
  func cloneRepository(_ sender: Any?)
  {
    if let openPanel = openPanel {
      openPanel.close()
      self.openPanel = nil
    }
    ClonePanelController.instance.showWindow(sender)
  }
  
  @IBAction
  func openDocument(_ sender: Any?)
  {
    guard !isTerminating else { return }
    if let openPanel = openPanel {
      openPanel.makeKeyAndOrderFront(self)
      return
    }
    if ClonePanelController.isShowingPanel {
      ClonePanelController.instance.close()
    }

    Task {
      guard !isTerminating else { return }
      let newOpenPanel = NSOpenPanel()

      openPanel = newOpenPanel
      newOpenPanel.canChooseFiles = false
      newOpenPanel.canChooseDirectories = true
      newOpenPanel.delegate = self
      newOpenPanel.messageString = .openPrompt

      if await newOpenPanel.begin() == .OK, !isTerminating {
        for url in newOpenPanel.urls {
          NSDocumentController.shared.openDocument(
              withContentsOf: url,
              display: true) { (_, _, _) in }
        }
      }
      self.openPanel = nil
    }
  }
  
  
  private var isTerminating: Bool {
    (NSDocumentController.shared as? HelmDocumentController)?
      .worktrees.isTerminating == true
  }

  func cancelOpenPanelForTermination()
  {
    let panel = openPanel
    openPanel = nil
    panel?.cancel(nil)
  }

  @MainActor
  func activeWindowController() -> HelmWindowController?
  {
    guard let controller = NSApp.mainWindow?.windowController
                           as? HelmWindowController
    else { return nil }

    return controller
  }
  
  @objc
  func dismissOpenPanel()
  {
    if let panel: NSOpenPanel = NSApp.windows.firstOfType() {
      panel.close()
    }
  }
}

extension AppDelegate: NSMenuDelegate
{
  func menuNeedsUpdate(_ menu: NSMenu)
  {
    if menu == remoteSettingsSubmenu {
      activeWindowController()?.updateRemotesMenu(menu)
    }
  }
}

extension AppDelegate: NSOpenSavePanelDelegate
{
  func panel(_ sender: Any, validate url: URL) throws
  {
    let repoURL = url.appendingPathComponent(".git", isDirectory: true)
    
    if FileManager.default.fileExists(atPath: repoURL.path) {
      return
    }
    else {
      if let window = sender as? NSWindow {
        let alert = NSAlert()
        
        alert.messageString = .notARepository
        alert.beginSheetModal(for: window)
      }
      throw NSError(domain: NSCocoaErrorDomain,
                    code: CocoaError.featureUnsupported.rawValue)
    }
  }
}

extension AppDelegate: NSApplicationDelegate
{
  func applicationWillFinishLaunching(_ note: Notification)
  {
    HelmRepository.initialize()

    // The first NSDocumentController instance becomes the shared one.
    _ = HelmDocumentController()
    
    let defaultsURL = Bundle.main.url(forResource: "Defaults",
                                      withExtension: "plist")!
    let defaults = NSDictionary(contentsOf: defaultsURL)!
    
    UserDefaults.standard.register(defaults: defaults as! [String: Any])
  }
  
  func applicationDidFinishLaunching(_ note: Notification)
  {
    (NSDocumentController.shared as? HelmDocumentController)?
      .sessions.restoreIfNeeded()
    if !UserDefaults.standard.bool(forKey: "noServices") {
      Services.helm.initializeServices(with: AccountsManager.helm)
    }
  }
  
  func applicationShouldTerminate(_ sender: NSApplication)
      -> NSApplication.TerminateReply
  {
    let allowed = (NSDocumentController.shared as? HelmDocumentController)?
      .prepareForTermination() ?? true
    return allowed ? .terminateNow : .terminateCancel
  }

  func applicationOpenUntitledFile(_ app: NSApplication) -> Bool
  {
    guard !isTerminating else { return true }
    let restored = (NSDocumentController.shared as? HelmDocumentController)?
      .sessions.restoreIfNeeded() ?? false
    if !restored { openDocument(nil) }
    // Returning true prevents the app from opening an untitled document
    // on its own.
    return true
  }
}
