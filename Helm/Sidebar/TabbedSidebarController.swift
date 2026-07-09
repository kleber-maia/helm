import AppKit
import SwiftUI
import Combine

/// AppKit wrapper that hosts the SwiftUI sidebar and bridges it back to the
/// existing window-controller operation flow.
@MainActor
final class TabbedSidebarController: NSHostingController<AnyView>
{
  weak var controller: HelmWindowController?
  private var sinks: [AnyCancellable] = []
  private var notificationObservers: [NSObjectProtocol] = []

  /// Local mouse monitor used to detect clicks on the already-selected sidebar
  /// row, which SwiftUI's `List` otherwise ignores.
  private var reselectMonitor: Any?

  /// The `NSTableView` (actually an `NSOutlineView`) backing the SwiftUI list,
  /// looked up lazily once the view hierarchy exists.
  private weak var sidebarTableView: NSTableView?

  /// Shared sidebar state injected into the SwiftUI hierarchy.
  let coordinator = SidebarCoordinator()

  /// Shared branch accessory renderer injected into local and remote lists.
  let accessories = BranchAccessoryStore()

  /// Cached SwiftUI sidebar models retained across tab switches and refreshed
  /// in response to explicit sidebar reloads.
  private let viewModels: any SidebarViewModelRefreshing

  init(repo: some FullRepository,
       workspaceCountModel: WorkspaceStatusCountModel,
       controller: HelmWindowController)
  {
    self.controller = controller
    let viewModels = SidebarViewModel(brancher: repo,
                                      detector: repo,
                                      remoteManager: repo,
                                      referencer: repo,
                                      publisher: controller.repoController,
                                      stasher: repo,
                                      submoduleManager: repo,
                                      tagger: repo,
                                      workspaceCountModel: workspaceCountModel)
    self.viewModels = viewModels

    coordinator.expandedItems = .init(
      [
        SidebarTreeSection.branches.path,
        SidebarTreeSection.remotes.path,
        SidebarTreeSection.submodules.path,
      ] + repo.remoteNames().map {
        SidebarTreeItem.remote($0).treeNodePath
      })

    let view = TabbedSidebar(model: viewModels)
      .environment(\.showError) { [weak controller] error in
        controller?.showAlert(nsError: error)
      }
      .environmentObject(coordinator)
      .environmentObject(accessories)

    super.init(rootView: AnyView(view))
    coordinator.delegate = self
    observeSidebarSelection(repo: repo)
  }
  
  required dynamic init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad()
  {
    super.viewDidLoad()
    // Let the AppKit NSVisualEffectView (sidebar material) from
    // NSSplitViewItem(sidebarWithViewController:) show through.
    view.wantsLayer = true
    view.layer?.backgroundColor = .clear
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    installReselectMonitorIfNeeded()
    installWindowObserversIfNeeded()
    updateTopContentInset()
  }

  override func viewDidLayout()
  {
    super.viewDidLayout()
    updateTopContentInset()
  }

  deinit
  {
    if let reselectMonitor {
      NSEvent.removeMonitor(reselectMonitor)
    }
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Installs a non-consuming local mouse monitor. Clicking the row that is
  /// already selected does not change SwiftUI's `List` selection, so the
  /// history view would otherwise stay on whatever commit the user had
  /// navigated to. The monitor detects a click landing on the already-selected
  /// row (before the table processes it) and re-applies that selection, while
  /// returning the event untouched so native selection and focus still work.
  private func installReselectMonitorIfNeeded()
  {
    guard reselectMonitor == nil
    else { return }

    reselectMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      self?.handlePotentialReselect(event)
      return event
    }
  }

  private func handlePotentialReselect(_ event: NSEvent)
  {
    guard let window = view.window,
          event.window === window,
          let table = sidebarTable(),
          let selection = coordinator.selection
    else { return }

    let point = table.convert(event.locationInWindow, from: nil)

    guard table.bounds.contains(point)
    else { return }

    let row = table.row(at: point)

    guard row != -1,
          row == table.selectedRow
    else { return }

    DispatchQueue.main.async {
      [weak self] in
      self?.coordinator.reselect(selection)
    }
  }

  private func sidebarTable() -> NSTableView?
  {
    if let sidebarTableView {
      return sidebarTableView
    }

    let found = view.firstDescendant(ofType: NSTableView.self)

    sidebarTableView = found
    return found
  }

  private func installWindowObserversIfNeeded()
  {
    guard notificationObservers.isEmpty,
          let window = view.window
    else { return }

    let names: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didResizeNotification,
    ]

    notificationObservers = names.map { name in
      NotificationCenter.default.addObserver(forName: name,
                                             object: window,
                                             queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.updateTopContentInset()
        }
      }
    }
  }

  private func updateTopContentInset()
  {
    guard let window = view.window,
          window.styleMask.contains(.fullScreen)
    else {
      setTopContentInset(0)
      return
    }

    let inset = fullScreenTopSystemOverlap(for: window)

    setTopContentInset(inset)
  }

  private func setTopContentInset(_ inset: CGFloat)
  {
    guard coordinator.topContentInset != inset
    else { return }

    coordinator.topContentInset = inset
  }

  private func fullScreenTopSystemOverlap(for window: NSWindow) -> CGFloat
  {
    let layoutRect = view.convert(window.contentLayoutRect, from: nil)

    return max(0, view.bounds.maxY - layoutRect.maxY)
  }

  /// Requests that cached sidebar models refresh their visible data.
  func refresh()
  {
    coordinator.refresh()
  }

  private func observeSidebarSelection(repo: some FullRepository)
  {
    sinks.append(coordinator.$selection.dropFirst().sinkOnMainQueue {
      [weak self] selection in
      self?.applyRepositorySelection(for: selection, repo: repo)
    })
  }

  private func applyRepositorySelection(for selection: SidebarTreeSelection?,
                                        repo: some FullRepository)
  {
    switch selection {
      case .staging:
        controller?.selection = StagingSelection(repository: repo, amending: false)
      case .localBranch(let refName):
        guard let branch = repo.localBranch(named: refName),
              let commit = branch.targetCommit
        else { return }
        controller?.selection = CommitSelection(repository: repo, commit: commit)
      case .remoteBranch(let refName):
        guard let branch = repo.remoteBranch(named: refName.localName,
                                             remote: refName.remoteName),
              let commit = branch.targetCommit
        else { return }
        controller?.selection = CommitSelection(repository: repo, commit: commit)
      case .tag(let selection):
        guard let tag = repo.tag(named: selection),
              let commit = tag.commit
        else { return }
        controller?.selection = CommitSelection(repository: repo, commit: commit)
      case .stash(let selection):
        guard let index = repo.findStashIndex(selection)
        else { return }
        controller?.selection = StashSelection(repository: repo, index: UInt(index))
      case .section, .remote, .submodule, .none:
        return
    }
  }

  private func mergeLocalBranch(_ refName: LocalBranchRefName)
  {
    guard let branch =
        controller?.repository.localBranch(named: refName)
    else { return }

    executeAndReport({
      try self.controller?.repository.merge(branch: branch)
    }, onSuccess: notifyRefsAndIndexChanged)
  }

  private func performMergeRemoteBranch(
      _ refName: RemoteBranchRefName)
  {
    guard let branch =
        controller?.repository.remoteBranch(
            named: refName.localName,
            remote: refName.remoteName)
    else { return }

    executeAndReport({
      try self.controller?.repository.merge(branch: branch)
    }, onSuccess: notifyRefsAndIndexChanged)
  }

  private func runStashAction(
      _ stashID: GitOID,
      onSuccess: (@MainActor @Sendable () -> Void)? = nil,
      action: @escaping (Int) throws -> Void)
  {
    guard let index =
        controller?.repository.findStashIndex(stashID)
    else { return }

    executeAndReport({
      try action(index)
    }, onSuccess: onSuccess)
  }

  private func showSubmoduleInFinder(named submoduleName: String)
  {
    guard let submodule = controller?.repository.submodules()
      .first(where: { $0.name == submoduleName }),
      let repository = controller?.repository
    else { return }

    NSWorkspace.shared.activateFileViewerSelecting([
      repository.fileURL(submodule.path),
    ])
  }

  private func updateSubmodule(named submoduleName: String)
  {
    guard let controller,
          let submodule = controller.repository.submodules()
            .first(where: { $0.name == submoduleName })
    else { return }

    let callbacks = controller.remoteCallbacks(for: submodule.url)

    executeAndReport({
      try submodule.update(callbacks: callbacks)
    }, onSuccess: notifyRefsChanged)
  }

  private func copyRemoteURL(named remoteName: String)
  {
    guard let remoteURL = controller?.repository.config
      .urlString(remote: "remote.\(remoteName).url")
    else { return }

    copyToPasteboard(remoteURL)
  }

  private func copyToPasteboard(_ string: String)
  {
    let pasteboard = NSPasteboard.general

    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(string, forType: .string)
  }

  // MARK: Notifications

  private func notifyRefsChanged()
  {
    controller?.repoController.refsChanged()
  }

  private func notifyIndexChanged()
  {
    controller?.repoController.indexChanged()
  }

  private func notifyRefsAndIndexChanged()
  {
    controller?.repoController.refsChanged()
    controller?.repoController.indexChanged()
  }

  // MARK: Execution helpers

  private func executeAndReport(
      _ block: @escaping () throws -> Void,
      onSuccess: (@MainActor @Sendable () -> Void)? = nil)
  {
    controller?.repoController.queue.executeOffMainThread {
      do {
        try block()
        if let onSuccess {
          Task { @MainActor in onSuccess() }
        }
      }
      catch let error as RepoError {
        Task { @MainActor in
          self.controller?.showErrorMessage(error: error)
        }
      }
      catch let error as NSError {
        Task { @MainActor in
          self.controller?.showAlert(nsError: error)
        }
      }
    }
  }

  private func confirmDelete<T>(
      kind: UIString,
      name: String,
      info: UIString? = nil,
      onSuccess: (@MainActor @Sendable () -> Void)? = nil,
      action: @escaping (T) throws -> Void)
    -> (T) -> Void
  {
    { [weak self] value in
      guard let window = self?.controller?.window
      else { return }

      Task {
        guard await NSAlert.confirmDelete(
            kind: kind, name: name, info: info, window: window)
        else { return }
        self?.executeAndReport({
          try action(value)
        }, onSuccess: onSuccess)
      }
    }
  }
}

extension TabbedSidebarController: SidebarCoordinatorDelegate
{
  func newBranch()
  {
    guard let controller else { return }
    controller.startOperation {
      NewBranchOpController(windowController: controller)
    }
  }

  func newRemote()
  {
    guard let controller else { return }
    controller.startOperation {
      NewRemoteOpController(windowController: controller)
    }
  }

  func checkoutBranch(_ branch: LocalBranchRefName)
  {
    executeAndReport({
      try self.controller?.repository.checkOut(branch: branch)
    }, onSuccess: notifyRefsAndIndexChanged)
  }

  func mergeBranch(_ branch: LocalBranchRefName)
  {
    mergeLocalBranch(branch)
  }

  func renameBranch(_ branch: LocalBranchRefName)
  {
    guard let controller else { return }
    controller.startOperation {
      RenameBranchOpController(windowController: controller, branchName: branch)
    }
  }

  func deleteBranch(_ branch: LocalBranchRefName)
  {
    let hasTrackingBranch =
        controller?.repository.localBranch(named: branch)?.trackingBranch != nil
    let info: UIString? = hasTrackingBranch ? .remoteBranchNotDeleted : nil

    confirmDelete(kind: .ItemType.localBranch, name: branch.name,
                  info: info,
                  onSuccess: notifyRefsChanged) { value in
      try self.controller?.repository.deleteBranch(value)
    }(branch)
  }

  func deleteBranchAndRemote(_ branch: LocalBranchRefName)
  {
    guard let controller else { return }
    controller.startOperation {
      DeleteBranchOpController(branch: branch, windowController: controller)
    }
  }

  func createTrackingBranch(_ branch: RemoteBranchRefName)
  {
    guard let controller else { return }
    controller.startOperation {
      CheckOutRemoteOpController(windowController: controller, branch: branch)
    }
  }

  func mergeRemoteBranch(_ branch: RemoteBranchRefName)
  {
    performMergeRemoteBranch(branch)
  }

  func renameRemote(_ remote: String)
  {
    controller?.remoteSettings(remote: remote)
  }

  func editRemote(_ remote: String)
  {
    controller?.remoteSettings(remote: remote)
  }

  func deleteRemote(_ remote: String)
  {
    confirmDelete(kind: .ItemType.remote, name: remote,
                  onSuccess: notifyRefsChanged) { value in
      try self.controller?.repository.deleteRemote(named: value)
    }(remote)
  }

  func copyRemoteURL(_ remote: String)
  {
    copyRemoteURL(named: remote)
  }

  func copyBranchName(_ name: String)
  {
    copyToPasteboard(name)
  }

  func deleteTag(_ tag: TagRefName)
  {
    confirmDelete(kind: .ItemType.tag, name: tag.name,
                  onSuccess: notifyRefsChanged) { value in
      try self.controller?.repository.deleteTag(name: value)
    }(tag)
  }

  func popStash(_ stashID: GitOID)
  {
    runStashAction(stashID,
                   onSuccess: notifyIndexChanged) { index in
      try self.controller?.repository.popStash(index: UInt(index))
    }
  }

  func applyStash(_ stashID: GitOID)
  {
    runStashAction(stashID,
                   onSuccess: notifyIndexChanged) { index in
      try self.controller?.repository.applyStash(index: UInt(index))
    }
  }

  func dropStash(_ stashID: GitOID)
  {
    runStashAction(stashID) { index in
      try self.controller?.repository.dropStash(index: UInt(index))
    }
  }

  func showSubmoduleInFinder(_ name: String)
  {
    showSubmoduleInFinder(named: name)
  }

  func updateSubmodule(_ name: String)
  {
    updateSubmodule(named: name)
  }

  func refreshSidebar()
  {
    guard let controller
    else { return }

    if !controller.repoController.tryRefsChanged() {
      controller.deferLocalRefreshUntilQueueIdle()
    }
  }

  func reselect(_ selection: SidebarTreeSelection)
  {
    guard let repo = controller?.repository
    else { return }

    applyRepositorySelection(for: selection, repo: repo)
  }
}
