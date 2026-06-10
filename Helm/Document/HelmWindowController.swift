import Cocoa
import SwiftUI
import Combine

@MainActor
protocol RepositoryUIController: AnyObject
{
  var repository: any FullRepository { get }
  var repoController: GitRepositoryController! { get }
  var selection: (any RepositorySelection)? { get set }
  var selectionPublisher: AnyPublisher<RepositorySelection?, Never> { get }
  var reselectPublisher: AnyPublisher<Void, Never> { get }
  var isAmending: Bool { get set }

  func select(oid: GitOID)
  func reselect()
  func showAlert(message: UIString, info: UIString)
  func showAlert(nsError: NSError)
}

extension RepositoryUIController
{
  var selectionBinding: Binding<(any RepositorySelection)?>
  {
    .init {
      [weak self] in
      self?.selection
    }
    set: {
      [weak self] in
      self?.selection = $0
    }
  }

  func showErrorMessage(error: RepoError)
  {
    showAlert(message: error.message, info: .empty)
  }
}

extension RepositoryUIController
{
  var queue: TaskQueue { repoController.queue }
}

/// RepoDocument's main window controller.
final class HelmWindowController: NSWindowController,
                                RepositoryUIController
{
  var splitViewController: NSSplitViewController!
  @IBOutlet var titleBarController: TitleBarController!
  
  var historyController: HistoryViewController!
  var historySplitController: HistorySplitController!
  var contentPanelController: ContentPanelController!
  var reviewViewController: FileViewController!
  var tabbedSidebarController: TabbedSidebarController?
  var terminalPanelController: TerminalPanelViewController?
  weak var repoDocument: RepoDocument?
  var repoController: GitRepositoryController!
  var sinks: [AnyCancellable] = []
  var repository: any FullRepository
  { (repoDocument?.repository as (any FullRepository)?)! }
  let workspaceCountModel: WorkspaceStatusCountModel = .init()

  var defaults: UserDefaults = .helm

  @objc dynamic var isAmending = false
  {
    didSet { selectionChanged(oldValue: selection) }
  }
  var selection: (any RepositorySelection)?
  {
    didSet { selectionChanged(oldValue: oldValue) }
  }
  private let selectionSubject =
      CurrentValueSubject<RepositorySelection?, Never>(nil)
  public var selectionPublisher: AnyPublisher<RepositorySelection?, Never>
  { selectionSubject.eraseToAnyPublisher() }
  private let reselectSubject = PassthroughSubject<Void, Never>()
  public var reselectPublisher: AnyPublisher<Void, Never>
  { reselectSubject.eraseToAnyPublisher() }

  var navBackStack = [any RepositorySelection]()
  var navForwardStack = [any RepositorySelection]()
  var navigating = false
  var currentOperation: OperationController?
  
  private var kvObservers: [NSKeyValueObservation] = []
  private var splitObserver: NSObjectProtocol?
  private var terminalRestored = false
  private var autoFetchTimer: Timer?
  private var lastFetchAt: Date?
  private var autoFetchInterval: TimeInterval = 60
  private var tabTitleBranchName: String?
  private var refreshLocalStateWhenQueueIdle = false

  nonisolated private static func currentAutoFetchInterval() -> TimeInterval
  {
    let task = Process()

    task.launchPath = "/usr/bin/pmset"
    task.arguments = ["-g", "ps"]

    let pipe = Pipe()

    task.standardOutput = pipe
    try? task.run()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8)
    else { return 60 }
    return output.contains("Battery Power") ? 300 : 60
  }

  private func refreshAutoFetchInterval()
  {
    Task.detached {
      [weak self] in
      let interval = Self.currentAutoFetchInterval()

      await MainActor.run {
        self?.autoFetchInterval = interval
      }
    }
  }

  override func close()
  {
    stopAutoFetch()
    currentOperation?.canceled = true
    splitObserver.map { NotificationCenter.default.removeObserver($0) }
    super.close()
  }

  // MARK: Auto-fetch

  func startAutoFetch()
  {
    guard currentOperation == nil,
          window?.isMainWindow == true
    else { return }
    guard autoFetchTimer == nil
    else { return }

    refreshAutoFetchInterval()
    let interval = autoFetchInterval
    let nextDelay: TimeInterval

    if lastFetchAt == nil {
      repoLogger.publicInfo("autoFetch initial")
      refreshWithFetch()
      nextDelay = interval
    }
    else if let lastFetchAt,
            Date().timeIntervalSince(lastFetchAt) >= interval {
      refreshWithFetch()
      nextDelay = interval
    }
    else if let lastFetchAt {
      nextDelay = interval - Date().timeIntervalSince(lastFetchAt)
    }
    else {
      nextDelay = interval
    }

    autoFetchTimer = Timer.scheduledTimer(
        withTimeInterval: nextDelay,
        repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.autoFetchTimer = nil
        self.startAutoFetch()
      }
    }
  }

  func stopAutoFetch()
  {
    autoFetchTimer?.invalidate()
    autoFetchTimer = nil
  }

  func refreshLocalState()
  {
    if !repoController.tryRefsChanged() {
      deferLocalRefreshUntilQueueIdle()
    }

    historyController.reload()
    tabbedSidebarController?.refresh()
    titleBarController.refreshCodexBarUsageAfterRepositoryRefresh()
  }

  func deferLocalRefreshUntilQueueIdle()
  {
    refreshLocalStateWhenQueueIdle = true
  }

  func refreshWithFetch()
  {
    lastFetchAt = Date()
    repoLogger.publicInfo("refreshWithFetch begin")
    guard let repo = repoDocument?.repository
          as? HelmRepository
    else {
      repoLogger.publicInfo("refreshWithFetch localOnly reason=notHelmRepository")
      refreshLocalState()
      return
    }

    refreshLocalState()

    let config = repo.config
    let remoteNames = repo.remoteNames()

    guard !remoteNames.isEmpty
    else {
      repoLogger.publicInfo("refreshWithFetch noRemotes")
      return
    }

    repoLogger.publicInfo("""
        refreshWithFetch enqueue remotes=\(remoteNames.joined(separator: ","))
        """)
    repoController.queue.executeOffMainThread {
      for name in remoteNames {
        guard let remote = repo.remote(named: name)
        else {
          repoLogger.publicError("refreshWithFetch missingRemote name=\(name)")
          continue
        }

        let started = Date()
        let callbacks = RemoteCallbacks(passwordBlock: { [weak self] in
          self?.passwordPrompt(for: remote.url)
        })
        let options = FetchOptions(
              downloadTags: config.fetchTags(remote: name),
              pruneBranches: config.fetchPrune(remote: name),
              callbacks: callbacks)

        do {
          repoLogger.publicInfo("refreshWithFetch fetch begin remote=\(name)")
          try repo.fetch(remote: remote, options: options)
          repoLogger.publicInfo("""
              refreshWithFetch fetch end remote=\(name) \
              duration=\(Date().timeIntervalSince(started))
              """)
        }
        catch {
          repoLogger.publicError("""
              refreshWithFetch fetch failed remote=\(name) \
              duration=\(Date().timeIntervalSince(started)) \
              error=\(String(describing: error))
              """)
        }
      }
      Task { @MainActor in
        self.refreshLocalState()
        repoLogger.publicInfo("refreshWithFetch end")
      }
    }
  }

  func finalizeSetup()
  {
    guard document != nil,
          let window = self.window
    else {
      preconditionFailure("HelmWindowController not configured")
    }
    
    repoDocument = document as! RepoDocument?
    
    guard let repo = repoDocument?.repository
    else { return }
    
    if let headOID = repo.headOID,
       let headCommit = repo.commit(forOID: headOID) {
      selection = CommitSelection(repository: repo, commit: headCommit)
    }
    repoController = GitRepositoryController(repository: repo)
    workspaceCountModel.subscribe(to: repoController, detector: repo)
    
    sinks.append(contentsOf: [
      repo.currentBranchPublisher.sink {
        [weak self] branch in
        DispatchQueue.main.async {
          self?.tabTitleBranchName = branch?.name
          self?.applyTabTitle()
        }
      },
      workspaceCountModel.$counts.sinkOnMainQueue {
        [weak self] in
        self?.updateTabStatus(staged: $0.staged, unstaged: $0.unstaged)
        self?.applyTabTitle()
      },
      repoController.queue.busyPublisher.sinkOnMainQueue {
        [weak self] busy in
        guard let self,
              !busy,
              self.refreshLocalStateWhenQueueIdle
        else { return }

        self.refreshLocalStateWhenQueueIdle = false
        self.refreshLocalState()
      }
    ])
    historyController.finishLoad(repository: repo)
    configureTitleBarController(repository: repo)
    updateTabStatus(staged: workspaceCountModel.counts.staged,
                    unstaged: workspaceCountModel.counts.unstaged)
    updateWindowStyle(window)
    titleBarController?.updateCustomActionButton(
        repoPath: repo.repoURL.path)

    let tabbedSidebarController =
        TabbedSidebarController(repo: repo,
                                workspaceCountModel: workspaceCountModel,
                                controller: self)
    self.tabbedSidebarController = tabbedSidebarController
    let tabbedSidebarItem =
          NSSplitViewItem(sidebarWithViewController: tabbedSidebarController)

    tabbedSidebarItem.minimumThickness = 200
    tabbedSidebarItem.preferredThicknessFraction = 0.25
    splitViewController.splitViewItems.remove(at: 0)
    splitViewController.splitViewItems.insert(tabbedSidebarItem, at: 0)

    let repoRoot = repo.repoURL.path
    let agent = repository.config.codingAgent ?? defaults.codingAgent
    let terminalPanelController = TerminalPanelViewController(workingDirectory: repoRoot,
                                                              agent: agent)
    self.terminalPanelController = terminalPanelController

    let terminalItem = NSSplitViewItem(viewController: terminalPanelController)

    terminalItem.canCollapse = true
    splitViewController.addSplitViewItem(terminalItem)

    let review = FileViewController(nibName: .fileViewControllerNib, bundle: nil)

    review.startsOnFilesTab = true
    review.isReviewPanel = true
    reviewViewController = review

    let contentPanel = ContentPanelController()

    contentPanelController = contentPanel
    _ = contentPanel.view

    let historyItem = splitViewController.splitViewItems[1]

    splitViewController.removeSplitViewItem(historyItem)
    contentPanel.configure(historySplit: historySplitController, review: review)

    let contentItem = NSSplitViewItem(viewController: contentPanel)

    splitViewController.insertSplitViewItem(contentItem, at: 1)
    review.finishLoad(repository: repo)
    // Initialize review list controllers now — viewWillAppear won't fire
    // until the review panel is first shown.
    review.initializeListControllers()
  }
  
  func updateWindowStyle(_ window: NSWindow)
  {
    guard let toolbar = window.toolbar
    else {
      assertionFailure("no toolbar")
      return
    }
    var style = window.styleMask

    style.formUnion([.fullSizeContentView])
    if !toolbar.items.contains(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) {
      toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: 0)
    }
    if !toolbar.items.contains(
        where: { $0.itemIdentifier == .customAction }) {
      // Insert right after the sidebar separator (leading)
      let insertIndex = min(1, toolbar.items.count)
      toolbar.insertItem(withItemIdentifier: .customAction,
                         at: insertIndex)
    }
    if let codingAgentIndex = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == .codingAgent
    }) {
      toolbar.removeItem(at: codingAgentIndex)
    }
    if !toolbar.items.contains(where: {
      $0.itemIdentifier == .codingAgentUsageGroup
    }) {
      // Insert after custom action
      let insertIndex = min(2, toolbar.items.count)
      toolbar.insertItem(withItemIdentifier: .codingAgentUsageGroup,
                         at: insertIndex)
    }
    let groupIndex = toolbar.items.firstIndex {
      $0.itemIdentifier == .codingAgentUsageGroup
    } ?? 2
    let itemAfterGroup = groupIndex + 1 < toolbar.items.count
        ? toolbar.items[groupIndex + 1]
        : nil

    if itemAfterGroup?.itemIdentifier != .space {
      toolbar.insertItem(withItemIdentifier: .space,
                         at: min(groupIndex + 1, toolbar.items.count))
    }
    if !toolbar.items.contains(where: { $0.itemIdentifier == .newBranch }) {
      let insertIndex = min(groupIndex + 2, toolbar.items.count)

      toolbar.insertItem(withItemIdentifier: .newBranch,
                         at: insertIndex)
    }
    window.styleMask = style
  }

  @objc
  func shutDown()
  {
    repoController.queue.shutDown()
    currentOperation?.abort()
    WaitForQueue(repoController.queue.queue)
  }

  func updateHistoryCollapse(wasStaging: Bool)
  {
    guard let repo = repoDocument?.repository
    else {
      assertionFailure("no repository")
      return
    }
    guard contentPanelController != nil
    else { return }

    if let stagingSelection = selection as? StagingSelection {
      if isAmending != stagingSelection.amending {
        selection = StagingSelection(repository: repo, amending: isAmending)
      }
      contentPanelController.showReview(true)
      titleBarController?.reviewActive = true
    }
    else {
      contentPanelController.showReview(false)
      titleBarController?.reviewActive = false
      if selection is StagedUnstagedSelection {
        if !historyController.historyHidden {
          historySplitController.toggleHistory(self)
        }
      }
      else if wasStaging && historyController.historyHidden {
        historySplitController.toggleHistory(self)
      }
    }
  }

  func selectionChanged(oldValue: (any RepositorySelection)?)
  {
    updateHistoryCollapse(wasStaging: oldValue is StagingSelection)
    if let newSelection = selection,
       let oldSelection = oldValue,
       newSelection == oldSelection {
      reselectSubject.send()
      return
    }

    selectionSubject.send(selection)

    touchBar = makeTouchBar()

    if !navigating {
      navForwardStack.removeAll()
      oldValue.map { navBackStack.append($0) }
    }
    updateNavButtons()
  }
  
  func select(oid: GitOID)
  {
    guard let repo = repoDocument?.repository,
          let commit = repo.commit(forOID: oid)
    else { return }
  
    selection = CommitSelection(repository: repo, commit: commit)
  }

  func reselect()
  {
    reselectSubject.send()
  }

  nonisolated func passwordPrompt(for remoteURL: URL?) -> (String, String)?
  {
    let host = remoteURL?.host ?? ""
    let started = Date()

    repoLogger.publicInfo("""
        passwordPrompt begin host=\(host.isEmpty ? "[empty]" : host)
        """)
    guard !Thread.isMainThread
    else {
      repoLogger.publicError("passwordPrompt failed reason=mainThread")
      assertionFailure("password prompt called on the main thread")
      return nil
    }

    repoLogger.publicDebug("passwordPrompt createSheet request")
    let sheetController = DispatchQueue.main.sync {
      PasswordPanelController()
    }
    repoLogger.publicDebug("passwordPrompt window request")
    guard let window = DispatchQueue.main.sync(execute: {
      MainActor.assumeIsolated {
        self.window
      }
    })
    else {
      repoLogger.publicError("passwordPrompt failed reason=missingWindow")
      return nil
    }

    let path = remoteURL?.path ?? ""
    let port = UInt16(remoteURL?.port ?? remoteURL?.defaultPort ?? 80)

    let result = sheetController.getPassword(parentWindow: window,
                                             host: host,
                                             path: path,
                                             port: port)

    repoLogger.publicInfo("""
        passwordPrompt end result=\(result == nil ? "nil" : "credentials") \
        duration=\(Date().timeIntervalSince(started))
        """)
    return result
  }

  func remoteCallbacks(for remoteURL: URL?) -> RemoteCallbacks
  {
    let progress = RemoteProgressPublisher(passwordBlock: { [weak self] in
      self?.passwordPrompt(for: remoteURL)
    })

    return progress.callbacks
  }

  nonisolated func updateMiniwindowTitle()
  {
    DispatchQueue.main.async {
      [weak self] in
      self?.applyTabTitle()
    }
  }

  /// Refreshes `window.miniwindowTitle` and the tab title. When the repo
  /// has uncommitted changes, the tab title is rendered as an attributed
  /// string prefixed with an accent-colored bullet; otherwise the plain
  /// title is used. Must be called on the main thread.
  private func applyTabTitle()
  {
    guard let window = self.window,
          let repo = self.repoDocument?.repository
    else { return }

    let plain: String

    if let currentBranch = tabTitleBranchName {
      plain = "\(window.title) - \(currentBranch)"
    }
    else {
      plain = window.title
    }

    let counts = workspaceCountModel.counts
    let isDirty = counts.staged > 0 || counts.unstaged > 0
    let tab = window.tab

    window.miniwindowTitle = plain
    if isDirty {
      tab.attributedTitle = Self.attributedTabTitle(plain: plain)
    }
    else {
      tab.attributedTitle = nil
      tab.title = plain
    }
  }

  private static func attributedTabTitle(plain: String) -> NSAttributedString
  {
    let bullet = NSAttributedString(
        string: "● ",
        attributes: [.foregroundColor: NSColor.controlAccentColor])
    let result = NSMutableAttributedString()

    result.append(bullet)
    result.append(NSAttributedString(string: plain))
    return result
  }

  fileprivate func updateTabStatus(staged: Int, unstaged: Int)
  {
    guard let tab = window?.tab
    else { return }

    guard defaults.statusInTabs
    else {
      tab.accessoryView = nil
      return
    }

    let tabButton = tab.accessoryView as? WorkspaceStatusIndicator ??
                    WorkspaceStatusIndicator()

    tabButton.setStatus(unstaged: unstaged, staged: staged)
    tabButton.setAccessibilityIdentifier("tabStatus")
    tab.accessoryView = tabButton
  }

  public func startRenameBranch(_ branchName: LocalBranchRefName)
  {
    _ = startOperation { RenameBranchOpController(windowController: self,
                                                  branchName: branchName) }
  }
  
  func updateRemotesMenu(_ menu: NSMenu)
  {
    let remoteNames = repository.remoteNames()

    menu.items = remoteNames.map { NSMenuItem($0, remoteSettings(_:)) }
  }
  
  func restartTerminal(with agent: CodingAgent)
  {
    terminalPanelController?.restart(with: agent)
  }

  func redrawAllHistoryLists()
  {
    for document in NSDocumentController.shared.documents {
      guard let windowController = document.windowControllers.first
                                   as? HelmWindowController
      else { continue }
      
      windowController.historyController.tableController.refreshText()
    }
  }
  
}

extension HelmWindowController: NSWindowDelegate
{
  override func windowDidLoad()
  {
    super.windowDidLoad()

    let window = self.window!

    Signpost.event(.windowControllerLoad)
    window.delegate = self
    window.toolbar?.displayMode = .iconAndLabel
    sizeWindowIfNeeded(window)
    splitViewController = contentViewController as? NSSplitViewController
    titleBarController.splitView = splitViewController.splitView

    historySplitController = splitViewController.splitViewItems[1].viewController
                             as? HistorySplitController
    historyController = historySplitController.historyController
    _ = historyController.view // force load

    window.makeFirstResponder(historyController.historyTable)

    kvObservers.append(window.observe(\.title) {
      [weak self] (_, _) in
      self?.updateMiniwindowTitle()
    })
    kvObservers.append(defaults.observe(\.deemphasizeMerges) {
      [weak self] (_, _) in
      MainActor.assumeIsolated { self?.redrawAllHistoryLists() }
    })
    kvObservers.append(defaults.observe(\.statusInTabs) {
      [weak self] (_, _) in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.updateTabStatus(staged: self.workspaceCountModel.counts.staged,
                             unstaged: self.workspaceCountModel.counts.unstaged)
      }
    })
    splitObserver = NotificationCenter.default.addObserver(
        forName: NSSplitView.didResizeSubviewsNotification,
        object: historySplitController.splitView, queue: .main) {
      [weak self] (_) in
      guard let self = self
      else { return }
      MainActor.assumeIsolated {
        let split = self.historySplitController.splitView
        let frameSize = split.subviews[0].frame.size
        let paneSize = split.isVertical ? frameSize.width : frameSize.height
        let collapsed = paneSize == 0

        self.titleBarController?.setSearchEnabled(!collapsed)
      }
    }

    updateMiniwindowTitle()
    updateNavButtons()
  }

  /// On first launch (no saved frame), size the window to 80 % of
  /// the visible screen area and center it.
  private func sizeWindowIfNeeded(_ window: NSWindow)
  {
    let name = window.frameAutosaveName
    guard !name.isEmpty,
          !window.setFrameUsingName(name)
    else { return }

    guard let screen = window.screen ?? NSScreen.main
    else { return }

    let visible = screen.visibleFrame
    let width = visible.width * 0.8
    let height = visible.height * 0.8
    let x = visible.origin.x + (visible.width - width) / 2
    let y = visible.origin.y + (visible.height - height) / 2
    let frame = NSRect(x: x, y: y, width: width, height: height)

    window.setFrame(frame, display: false)
  }

  func windowDidBecomeMain(_ notification: Notification)
  {
    if !terminalRestored {
      terminalRestored = true

      let split = splitViewController.splitView

      if split.bounds.width > 0, split.subviews.count >= 3 {
        split.setPosition(split.bounds.width * 0.6,
                          ofDividerAt: 1)
      }
    }
    terminalPanelController?.windowDidBecomeMain()
    startAutoFetch()
    if let toolbarDelegate = NSApp.mainWindow?.toolbar?.delegate
       as? TitleBarController {
      toolbarDelegate.refreshCodingAgentItem()
    }
  }

  func windowDidResignMain(_ notification: Notification)
  {
    terminalPanelController?.windowDidResignMain()
    stopAutoFetch()
  }

  func windowWillClose(_ notification: Notification)
  {
    stopAutoFetch()
    titleBarController.spinner?.unbind(◊"hidden")
    // For some reason this avoids a crash
    window?.makeFirstResponder(nil)
  }
}

extension HelmWindowController: NSMenuDelegate
{
  enum RemoteMenuType: CaseIterable
  {
    case fetch, push, pull

    var identifier: NSUserInterfaceItemIdentifier
    {
      switch self {
        case .fetch: return ◊"fetchRemote"
        case .push:  return ◊"pushRemote"
        case .pull:  return ◊"pullRemote"
      }
    }
    var selector: Selector
    {
      switch self {
        case .fetch: return #selector(HelmWindowController.fetchRemote(_:))
        case .push:  return #selector(HelmWindowController.pushToRemote(_:))
        case .pull:  return #selector(HelmWindowController.pullRemote(_:))
      }
    }

    func command(for remote: String) -> UIString
    {
      switch self {
        case .fetch: return .fetchRemote(remote)
        case .push:  return .pushRemote(remote)
        case .pull:  return .pullRemote(remote)
      }
    }

    static func of(_ menu: NSMenu) -> RemoteMenuType?
    {
      return menu.items.firstResult {
        (item) in
        guard let id = item.identifier
        else { return nil }
        return allCases.first { $0.identifier == id }
      }
    }
  }
  
  func menuWillOpen(_ menu: NSMenu)
  {
    guard let type = RemoteMenuType.of(menu)
    else { return }

    for item in menu.items where item.action == type.selector {
      menu.removeItem(item)
    }

    for (index, remote) in self.repository.remoteNames().enumerated() {
      let item = NSMenuItem(titleString: type.command(for: remote),
                            action: type.selector,
                            keyEquivalent: "")

      item.tag = index
      menu.addItem(item)
    }
  }
}
