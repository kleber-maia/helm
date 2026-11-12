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
  private var lastPresentationDiagnostic: String?
  private var savedPresentation: RepositorySession.Window.Presentation?
  private var pendingSidebarWidth: CGFloat?
  private var sidebarReady = false
  private var applyingSidebarWidth = false
  private var restoringWindowMode = false
  private var fullScreenTransition = false
  private var windowPresentationPrepared = false
  private var terminalRestored = false
  private var lastEqualSplitWindowSize: NSSize?
  private var lastObservedWindowSize: NSSize?
  private weak var observedResizeGroup: NSWindowTabGroup?
  private var equalSplitPending = true
  private var equalSplitGeneration: UInt64 = 0
  private var equalSplitScheduled = false
  private var applyingEqualSplit = false
  private var lastEqualSplitDiagnostic: String?
  private var autoFetchTimer: Timer?
  private var lastFetchAt: Date?
  private var autoFetchInterval: TimeInterval = 60
  private var tabTitleBranchName: String?
  var worktreeTransitionPending = false {
    didSet {
      repoDocument?.repository?.contextWritesBlocked = worktreeTransitionPending && currentOperation == nil
      if worktreeTransitionPending { stopAutoFetch() }
    }
  }
  var worktreesMenu: NSMenu?
  var worktreeAccessory: WorktreeTabAccessory?
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
    tabTitleBranchName = repo.currentBranch?.name
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
      repoController.headPublisher.sinkOnMainQueue { [weak self] in
        self?.applyTabTitle()
      },
      workspaceCountModel.$counts.sinkOnMainQueue {
        [weak self] in
        self?.updateTabStatus(staged: $0.staged, unstaged: $0.unstaged)
        self?.applyTabTitle()
      },
      repoController.queue.busyPublisher.sinkOnMainQueue {
        [weak self] busy in
        guard let self else { return }
        if !busy, let document = self.repoDocument {
          (NSDocumentController.shared as? HelmDocumentController)?
            .worktrees.retryPending(document)
        }
        guard !busy, self.refreshLocalStateWhenQueueIdle
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

    // Retain an initial/restored hidden state when replacing the storyboard item.
    tabbedSidebarItem.isCollapsed = splitViewController.splitViewItems[0].isCollapsed
    tabbedSidebarItem.minimumThickness = 180
    tabbedSidebarItem.preferredThicknessFraction = 0.2
    tabbedSidebarItem.holdingPriority = .init(260)
    tabbedSidebarItem.canCollapseFromWindowResize = false
    tabbedSidebarItem.collapseBehavior =
        .preferResizingSiblingsWithFixedSplitView
    splitViewController.minimumThicknessForInlineSidebars = 0
    splitViewController.splitViewItems.remove(at: 0)
    splitViewController.splitViewItems.insert(tabbedSidebarItem, at: 0)

    let repoRoot = repoDocument?.terminalDirectoryURL?.path ?? repo.repoURL.path
    let agent = repository.config.codingAgent ?? defaults.codingAgent
    let terminalPanelController = TerminalPanelViewController(workingDirectory: repoRoot,
                                                              agent: agent)
    self.terminalPanelController = terminalPanelController

    let terminalItem = NSSplitViewItem(viewController: terminalPanelController)

    terminalItem.canCollapse = true
    terminalItem.minimumThickness = 240
    terminalItem.preferredThicknessFraction = 0.4
    terminalItem.isCollapsed = false
    // Above passive sibling resizing, below AppKit's divider-drag priority490.
    terminalItem.holdingPriority = .init(450)
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

    // History/diff absorbs sidebar-only width changes before the PTY.
    // Actual window size changes explicitly equalize both panes below.
    contentItem.holdingPriority = .init(249)
    splitViewController.insertSplitViewItem(contentItem, at: 1)
    review.finishLoad(repository: repo)
    // Initialize review list controllers now — viewWillAppear won't fire
    // until the review panel is first shown.
    review.initializeListControllers()
    if let split = splitViewController as? MainSplitController {
      split.contentLayoutDidChange = { [weak self] in
        self?.updateSidebarPresentation()
        self?.scheduleTerminalLayoutIfNeeded()
      }
      split.configureSidebarPolicy()
      if !(NSDocumentController.shared as? HelmDocumentController)!.sessions.isRestoringLayout {
        prepareWindowPresentation(nil)
      }
    }
    // The first main-window notification can arrive before the new split
    // children have usable geometry. Retry once the setup/layout turn ends.
    DispatchQueue.main.async { [weak self] in
      self?.restoreTerminalLayoutIfNeeded()
    }
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
    if !toolbar.items.contains(where: { $0.itemIdentifier == .worktrees }) {
      toolbar.insertItem(withItemIdentifier: .worktrees, at: min(2, toolbar.items.count))
    }
    if !toolbar.items.contains(where: { $0.itemIdentifier == .newBranch }) {
      let insertIndex = min(groupIndex + 2, toolbar.items.count)

      toolbar.insertItem(withItemIdentifier: .newBranch,
                         at: insertIndex)
    }
    // Keep the two ordinary action items adjacent even with a restored order.
    if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .worktrees }) {
      toolbar.removeItem(at: index)
      let branchIndex = toolbar.items.firstIndex { $0.itemIdentifier == .newBranch }
          ?? toolbar.items.count
      toolbar.insertItem(withItemIdentifier: .worktrees, at: branchIndex)
    }
    // Remove only legacy standalone Sidebar items. Both controls now share
    // the existing Navigation item, so native toolbar ordering cannot split them.
    while let index = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == .toggleSidebar
    }) {
      toolbar.removeItem(at: index)
    }
    titleBarController.installSidebarBesideNavigation(in: toolbar)
    window.styleMask = style
  }

  @IBAction
  func showHideSidebar(_ sender: Any?)
  {
    splitViewController.toggleSidebar(sender)
  }

  @IBAction
  func showHideTerminal(_ sender: Any?)
  {
    guard let terminal = terminalPanelController,
          let item = splitViewController.splitViewItem(for: terminal)
    else { return }

    item.isCollapsed.toggle()
    splitViewController.splitView.layoutSubtreeIfNeeded()
    if !item.isCollapsed { terminal.becomeTerminalFirstResponder() }
  }

  /// Native tab windows may skip their own resize callbacks while inactive.
  /// The selected window records actual frame-size changes for its whole group.
  /// A -> B -> A remains pending for siblings even when their old size was A.
  private func recordNativeWindowResize()
  {
    guard let window else { return }
    let group = window.tabGroup
    if let selected = group?.selectedWindow, selected !== window { return }
    let peers = (group?.windows ?? [window]).compactMap {
      $0.windowController as? HelmWindowController
    }
    let previous = peers.first(where: {
      $0.observedResizeGroup === group && $0.lastObservedWindowSize != nil
    })?.lastObservedWindowSize ?? lastObservedWindowSize
    let size = window.frame.size
    for peer in peers {
      peer.observedResizeGroup = group
      peer.lastObservedWindowSize = size
      if previous != size {
        peer.equalSplitPending = true
        peer.equalSplitGeneration &+= 1
        peer.scheduleTerminalLayoutIfNeeded()
      }
    }
  }

  private func scheduleTerminalLayoutIfNeeded()
  {
    guard !applyingEqualSplit, !equalSplitScheduled,
          equalSplitPending || !terminalRestored, let window else { return }
    if let selected = window.tabGroup?.selectedWindow, selected !== window { return }
    equalSplitScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.equalSplitScheduled = false
      self.restoreTerminalLayoutIfNeeded()
    }
  }

  private func logEqualSplit(_ phase: String)
  {
    guard let window else { return }
    let split = splitViewController.splitView
    let snapshot = "window=\(window.windowNumber) outer=\(window.frame.size) split=\(split.bounds) lastAppliedOuter=\(String(describing: lastEqualSplitWindowSize)) frames=\(split.arrangedSubviews.map { $0.frame }) pending=\(equalSplitPending) generation=\(equalSplitGeneration)"
    guard phase + snapshot != lastEqualSplitDiagnostic else { return }
    lastEqualSplitDiagnostic = phase + snapshot
    repoLogger.notice("equalSplit \(phase, privacy: .public) \(snapshot, privacy: .public)")
  }

  private func restoreTerminalLayoutIfNeeded()
  {
    guard !applyingEqualSplit, equalSplitPending || !terminalRestored,
          let window, let terminal = terminalPanelController,
          let item = splitViewController.splitViewItem(for: terminal),
          splitViewController.splitViewItems.count == 3 else { return }
    if let selected = window.tabGroup?.selectedWindow, selected !== window { return }
    let generation = equalSplitGeneration
    let size = window.frame.size
    applyingEqualSplit = true
    defer {
      applyingEqualSplit = false
      if generation != equalSplitGeneration { scheduleTerminalLayoutIfNeeded() }
    }
    // Flush the containing host first: an inactive tab's split subtree can
    // otherwise still have its previous host allocation when it is selected.
    window.contentView?.layoutSubtreeIfNeeded()
    let split = splitViewController.splitView
    split.layoutSubtreeIfNeeded()
    guard size == window.frame.size, split.bounds.width > 0,
          let host = window.contentView,
          abs(host.bounds.width - window.contentRect(forFrameRect: window.frame).width) <= 1,
          abs(split.bounds.width - host.bounds.width) <= 1 else {
      logEqualSplit("deferredHost")
      return
    }
    if !terminalRestored { item.isCollapsed = false }
    guard !item.isCollapsed,
          !splitViewController.splitViewItems[1].isCollapsed,
          split.arrangedSubviews.count == 3 else { return }
    let center = split.arrangedSubviews[1].frame
    let terminalFrame = split.arrangedSubviews[2].frame
    let gap = split.dividerThickness
    let available = terminalFrame.maxX - center.minX - gap
    guard available > 0, center.minX >= split.bounds.minX - 1,
          abs(terminalFrame.maxX - split.bounds.maxX) <= 1,
          abs(terminalFrame.minX - center.maxX - gap) <= 1 else {
      logEqualSplit("deferredAllocation")
      return
    }
    let lower = split.minPossiblePositionOfDivider(at: 1)
    let upper = split.maxPossiblePositionOfDivider(at: 1)
    guard lower <= upper else { return }
    let target = max(lower, min(upper, center.minX + available / 2))
    split.setPosition(target, ofDividerAt: 1)
    split.layoutSubtreeIfNeeded()
    let actualCenter = split.arrangedSubviews[1].frame
    let actualTerminal = split.arrangedSubviews[2].frame
    guard generation == equalSplitGeneration, size == window.frame.size,
          abs(actualCenter.maxX - target) <= 1,
          actualCenter.width > 0, actualTerminal.width > 0,
          abs(actualTerminal.maxX - split.bounds.maxX) <= 1 else {
      logEqualSplit("deferredTarget")
      return
    }
    terminalRestored = true
    equalSplitPending = false
    lastEqualSplitWindowSize = size
    if lastObservedWindowSize == nil { lastObservedWindowSize = size }
    logEqualSplit("applied")
  }

  @objc
  func shutDown()
  {
    repoController.queue.shutDown()
    currentOperation?.abort()
    repoController.queue.wait()
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

    let folder = repo.repoURL.lastPathComponent
    let suffix = tabTitleBranchName ?? repo.headOID.map {
      "HEAD@" + $0.description.prefix(7)
    }
    let plain = suffix.map { "\(folder)/\($0)" } ?? folder

    if window.title != plain { window.title = plain }
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

  func updateTabStatus(staged: Int, unstaged: Int)
  {
    refreshWorktreePresentation()
    worktreeAccessory?.setStatus(staged: staged, unstaged: unstaged,
                                enabled: defaults.statusInTabs)
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
    if WindowPersistence.isFixture { window.setFrameAutosaveName("") }
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
    if !name.isEmpty, window.setFrameUsingName(name) { return }

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
    guard repoDocument?.closeApproved != true else { return }
    updateSidebarPresentation()
    scheduleTerminalLayoutIfNeeded()
    bindTerminalDirectoryObserver()
    terminalPanelController?.windowDidBecomeMain()
    startAutoFetch()
    if let toolbarDelegate = NSApp.mainWindow?.toolbar?.delegate
       as? TitleBarController {
      toolbarDelegate.refreshCodingAgentItem()
    }
  }

  func windowDidResize(_ notification: Notification)
  {
    updateSidebarPresentation()
    savePresentationChange()
    recordNativeWindowResize()
    scheduleTerminalLayoutIfNeeded()
  }

  func windowDidMove(_ notification: Notification) { savePresentationChange() }

  func windowWillEnterFullScreen(_ notification: Notification)
  {
    guard !sessionController.isTerminating, let window else { return }
    var state = captureWindowPresentation()
    state.windowedFrame = NSStringFromRect(window.frame)
    state.windowedMode = window.isZoomed ? .zoomed : .normal
    state.mode = .fullScreen
    savedPresentation = state
    fullScreenTransition = true
  }
  func windowDidEnterFullScreen(_ notification: Notification)
  {
    fullScreenTransition = false
    restoringWindowMode = false
    savePresentationChange()
    repoLogger.notice("windowPresentation nativeFullScreenEntered")
  }
  func windowWillExitFullScreen(_ notification: Notification)
  { fullScreenTransition = true }
  func windowDidExitFullScreen(_ notification: Notification)
  {
    fullScreenTransition = false
    guard !sessionController.isTerminating else { return }
    restoringWindowMode = false
    savedPresentation?.mode = window?.isZoomed == true ? .zoomed : .normal
    savePresentationChange()
  }
  func windowDidFailToEnterFullScreen(_ window: NSWindow)
  {
    restoringWindowMode = false
    fullScreenTransition = false
    savedPresentation?.mode = window.isZoomed ? .zoomed : .normal
    savePresentationChange()
  }

  func windowDidResignMain(_ notification: Notification)
  {
    terminalPanelController?.windowDidResignMain()
    stopAutoFetch()
  }

  func windowWillClose(_ notification: Notification)
  {
    if let repoDocument {
      (NSDocumentController.shared as? HelmDocumentController)?
        .sessions.willClose(repoDocument)
    }
    // Native tab/window close can bypass NSDocument.close. A transferred
    // panel belongs to its destination; only stop the panel still owned here.
    if let panel = terminalPanelController, panel.parent === splitViewController {
      repoDocument?.closeApproved = true
      panel.suspendAutomaticStart()
      panel.terminalController.finishSessionForClose()
    }
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


extension HelmWindowController
{
  private var sessionController: RepositorySessionController {
    (NSDocumentController.shared as! HelmDocumentController).sessions
  }

  func prepareWindowPresentation(_ state: RepositorySession.Window.Presentation?, legacy: Bool = false)
  {
    savedPresentation = state
    windowPresentationPrepared = true
    sidebarReady = false
    pendingSidebarWidth = state.flatMap { state in
      state.sidebarWidth.map { CGFloat(state.restoredSidebarWidth(resolved: $0)) }
    }
    if state == nil, !legacy { pendingSidebarWidth = 240 }
    if let hidden = state?.sidebarHidden {
      (splitViewController as? MainSplitController)?.restoreSidebarHidden(hidden)
    }
    updateSidebarPresentation()
  }

  func restoreWindowPresentation()
  {
    guard let window, let state = savedPresentation else { return }
    let frame = NSRectFromString(state.windowedFrame ?? state.normalFrame)
    if frame.width >= 400, frame.height >= 300 {
      window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }
    updateSidebarPresentation()
    restoringWindowMode = state.mode != .normal
    // Native fullscreen entry is asynchronous and begins only after grouping.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      if state.mode == .fullScreen, !window.styleMask.contains(.fullScreen) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.toggleFullScreen(nil)
      }
      else if state.mode == .zoomed, !window.isZoomed {
        window.zoom(nil)
        self.restoringWindowMode = false
      }
      else { self.restoringWindowMode = false }
    }
  }

  func captureWindowPresentation() -> RepositorySession.Window.Presentation
  {
    guard let window else { return savedPresentation ?? .init(normalFrame: "") }
    var state = savedPresentation ?? .init(normalFrame: NSStringFromRect(window.frame))
    if !fullScreenTransition, !restoringWindowMode, !sessionController.isTerminating {
      if window.styleMask.contains(.fullScreen) { state.mode = .fullScreen }
      else {
        state.mode = window.isZoomed ? .zoomed : .normal
        state.windowedMode = state.mode
        state.windowedFrame = NSStringFromRect(window.frame)
        if !window.isZoomed { state.normalFrame = NSStringFromRect(window.frame) }
      }
    }
    if sidebarReady, let split = splitViewController as? MainSplitController {
      state.sidebarPolicyVersion = 1
      state.sidebarHidden = !split.sidebarIsPinned
      if split.sidebarIsPinned, !split.splitViewItems[0].isCollapsed {
        let width = split.splitView.arrangedSubviews.first?.frame.width ?? 0
        if width >= 180 { state.sidebarWidth = Double(width) }
      }
    }
    savedPresentation = state
    let geometry = "mode=\(state.mode.rawValue) nativeFullScreen=\(window.styleMask.contains(.fullScreen)) zoomed=\(window.isZoomed) frame=\(window.frame) sidebarLogicalWidth=\(state.sidebarWidth ?? 0) sidebarHidden=\(state.sidebarHidden ?? false) policy=\(state.sidebarPolicyVersion ?? 0)"
    if geometry != lastPresentationDiagnostic {
      lastPresentationDiagnostic = geometry
      repoLogger.notice("windowPresentation \(geometry, privacy: .public)")
    }
    return state
  }

  private func updateSidebarPresentation()
  {
    guard windowPresentationPrepared, !applyingSidebarWidth,
          let window, window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window,
          let split = splitViewController as? MainSplitController,
          split.splitViewItems.count == 3, split.splitView.bounds.width > 600 else { return }
    guard split.sidebarIsPinned, !split.splitViewItems[0].isCollapsed else {
      // Never save zero or a transient overlay width over the last expanded width.
      return
    }
    let current = split.splitView.arrangedSubviews[0].frame.width
    guard current >= 180 else { return }
    if !sidebarReady {
      if pendingSidebarWidth == nil {
        // Legacy intent cannot be inferred: upgrade only the old exact minimum
        // once; all subsequent explicit widths (including 180) are preserved.
        pendingSidebarWidth = savedPresentation.map {
          CGFloat($0.restoredSidebarWidth(resolved: Double(current)))
        } ?? (abs(current - 180) <= 1 ? 240 : current)
      }
      let desired = pendingSidebarWidth!
      applyingSidebarWidth = true
      split.splitView.setPosition(desired, ofDividerAt: 0)
      split.splitView.layoutSubtreeIfNeeded()
      applyingSidebarWidth = false
      let actual = split.splitView.arrangedSubviews[0].frame.width
      let target = min(max(desired, split.splitView.minPossiblePositionOfDivider(at: 0)),
                       split.splitView.maxPossiblePositionOfDivider(at: 0))
      guard abs(actual - target) < 2 else { return }
      sidebarReady = true
      pendingSidebarWidth = nil
      repoLogger.notice("windowPresentation sidebarApplied logicalWidth=\(actual, privacy: .public)")
    }
    savePresentationChange()
  }

  private func savePresentationChange()
  {
    guard windowPresentationPrepared, !sessionController.isRestoringLayout,
          !sessionController.isTerminating, !fullScreenTransition, !restoringWindowMode else { return }
    let state = captureWindowPresentation()
    // A native tab group has one presentation; inactive hosts retain it without
    // sampling their stale or temporarily collapsed split geometry.
    for peer in window?.tabGroup?.windows ?? [] {
      guard let controller = peer.windowController as? HelmWindowController, controller !== self else { continue }
      controller.savedPresentation = state
      if !controller.sidebarReady { controller.pendingSidebarWidth = state.sidebarWidth.map { CGFloat($0) } }
    }
    sessionController.scheduleSave()
  }
}
