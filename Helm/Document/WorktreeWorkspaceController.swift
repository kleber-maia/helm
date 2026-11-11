import AppKit

/// Owns fixed Git/worktree bindings. Directory observations never mutate a
/// repository behind an existing controller: the intact terminal is adopted
/// by a controller that was opened for the destination worktree instead.
@MainActor
final class WorktreeWorkspaceController: NSObject
{
  private unowned let documents: HelmDocumentController
  private var inventories: [String: WorktreeInventory] = [:]
  private var inventoryRefreshFailures = Set<String>()
  private var watchers: [String: FileEventStream] = [:]
  private var pendingRefresh = Set<String>()
  private let reader = DispatchQueue(label: "helm.worktree-inventory", qos: .utility)
  private var transitioning = false
  private var pinning = false
  private var pendingMoves: [UUID: WorktreeRecord] = [:]
  private var removalRetry = Set<UUID>()
  private(set) var confirmedRemovedOnRestore = Set<UUID>()
  var isTerminating = false
  var isConfirmingTermination = false
  private var colorState = RepositoryColorAssignments()
  private static let colorStateKey = "worktreeRepositoryColorState.v2"
  private var colorStateNeedsSave = false
  private var pendingDirectories: [UUID: URL] = [:]
  private var mutatingRepositories = Set<String>()
  private var removingWorktrees = Set<String>()
  private struct RemovalSession {
    let terminal: TerminalViewController?
    let stamp: String
    let proof: TerminalRemovalProof
    let previousTransition: Bool
  }
  private var removalSessions: [String: [UUID: RemovalSession]] = [:]
  private var removalSheets: [String: [(NSWindow, NSPanel)]] = [:]
  private let defaults: UserDefaults
  static let colors = HistoryCellView.lineColors
  static let colorNames = ["Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Gray"]
  private static let colorKey = "worktreeRepositoryColors.v1"

  init(documents: HelmDocumentController, defaults: UserDefaults = .standard)
  {
    self.documents = documents
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.colorStateKey),
       let state = try? JSONDecoder().decode(RepositoryColorAssignments.self, from: data) {
      colorState = state
    }
    else {
      let legacy = defaults.data(forKey: "worktreeRepositoryColorState.v1")
        .flatMap { try? JSONDecoder().decode(RepositoryColorAssignments.self, from: $0) }
        ?? RepositoryColorAssignments(automatic: [:], overrides:
            defaults.dictionary(forKey: Self.colorKey) as? [String: Int] ?? [:])
      // v1 order: Teal, Blue, Indigo, Purple, Orange, Green. Keep originals;
      // map to matching branch colors, nearest Blue/Purple for Teal/Indigo.
      let mapping = [0, 0, 1, 1, 4, 6]
      colorState.overrides = legacy.overrides.compactMapValues {
        mapping.indices.contains($0) ? mapping[$0] : nil
      }
      var used = Set(colorState.overrides.values)
      for key in legacy.automatic.keys.sorted() {
        let old = legacy.automatic[key]!
        let preferred = mapping.indices.contains(old) ? mapping[old] : 0
        let index = !used.contains(preferred) ? preferred :
            ((0..<Self.colors.count).first { !used.contains($0) } ?? preferred)
        colorState.automatic[key] = index
        used.insert(index)
      }
      colorStateNeedsSave = true
    }
  }

  private var tabs: [RepoDocument] {
    documents.documents.compactMap { $0 as? RepoDocument }
  }

  func open(at url: URL, display: Bool = true) throws -> (RepoDocument, Bool)
  {
    guard !transitioning else { throw GitWorktreeCatalog.Failure.command("A worktree transition is completing; try again.") }
    let inventory = try GitWorktreeCatalog.discover(at: url)
    register(inventory)
    guard let target = record(containing: url, in: inventory) else {
      throw GitWorktreeCatalog.Failure.invalidInventory
    }
    guard !removingWorktrees.contains(target.id) else {
      throw GitWorktreeCatalog.Failure.command("This worktree is being removed; wait for completion.")
    }
    _ = try ensurePrimary(inventory, display: display)
    if let existing = preferred(target.id) {
      if existing.worktreeBinding?.record.path != target.path {
        reloadMoved(existing, as: target)
        return (preferred(target.id) ?? existing, true)
      }
      if display { existing.showWindows() }
      return (existing, true)
    }
    return (try create(target, display: display), false)
  }

  @discardableResult
  private func ensurePrimary(_ inventory: WorktreeInventory,
                             display: Bool) throws -> RepoDocument
  {
    if let document = tabs.first(where: {
      $0.worktreeBinding?.record.repositoryID == inventory.repositoryID &&
      $0.worktreeBinding?.isPinnedPrimary == true
    }) { return document }
    guard let primary = inventory.primary,
          primary.availability == .available else {
      throw GitWorktreeCatalog.Failure.command("The primary checkout is unavailable.")
    }
    return try create(primary, display: display)
  }

  private func preferred(_ id: String) -> RepoDocument?
  {
    let matches = tabs.filter { $0.worktreeBinding?.record.id == id }
    return matches.first { $0.worktreeBinding?.additionalSession == false }
           ?? matches.first
  }

  private func create(_ record: WorktreeRecord, id: UUID? = nil,
                      additional: Bool = false, display: Bool,
                      directory: URL? = nil) throws -> RepoDocument
  {
    let anchor = tabs.first {
      $0.worktreeBinding?.record.repositoryID == record.repositoryID
    }?.windowControllers.first?.window
    let insertionAnchor = anchor?.tabGroup?.windows.last ?? anchor
    let recovery = documents.sessions.recoverableTab(for: record)
    let sessionID = id ?? recovery?.id ?? UUID()
    let savedDirectory = RepositorySession.validDirectory(recovery?.terminalDirectory)
      .flatMap { url in
        inventories[record.repositoryID].flatMap {
          self.record(containing: url, in: $0)?.id == record.id ? url : nil
        }
      }
    let document = try documents.openRepository(
        at: URL(fileURLWithPath: record.path), id: sessionID,
        tabbingWith: insertionAnchor, display: display, terminalDirectory: directory ?? savedDirectory,
        binding: .init(record: record, additionalSession: additional))
    if !display { document.makeWindowControllers() }
    configure(document, anchor: insertionAnchor, show: display)
    documents.sessions.didRecover(sessionID)
    pinPrimaryTabs()
    return document
  }

  private func configure(_ document: RepoDocument, anchor: NSWindow?, show: Bool)
  {
    guard let window = document.windowControllers.first?.window,
          let binding = document.worktreeBinding else { return }
    window.tabbingIdentifier = binding.record.repositoryID
    window.tabbingMode = .disallowed
    if let anchor, anchor !== window, anchor.tabGroup !== window.tabGroup {
      anchor.addTabbedWindow(window, ordered: .above)
    }
    if show { document.showWindows() }
    window.tabbingMode = .automatic
    (window.windowController as? HelmWindowController)?.refreshWorktreePresentation()
  }

  func pinPrimaryTabs()
  {
    guard !transitioning, !pinning, !isTerminating else { return }
    pinning = true
    defer { pinning = false }
    let selected = NSApp.mainWindow
    let repositories = Set(tabs.compactMap { $0.worktreeBinding?.record.repositoryID })
    for common in repositories {
      if !tabs.contains(where: {
        $0.worktreeBinding?.record.repositoryID == common && $0.worktreeBinding?.isPinnedPrimary == true
      }), let inventory = inventories[common] {
        _ = try? ensurePrimary(inventory, display: true)
      }
    }
    for document in tabs where document.worktreeBinding?.isPinnedPrimary == true {
      guard let window = document.windowControllers.first?.window,
            let group = window.tabGroup, group.windows.first !== window
      else { continue }
      group.insertWindow(window, at: 0)
    }
    selected?.makeKeyAndOrderFront(nil)
  }

  func restore(_ saved: RepositorySession) -> [UUID: NSWindow]
  {
    var candidates: [WorktreeRestoreItem] = []
    confirmedRemovedOnRestore.removeAll()
    for tab in saved.windows.flatMap(\.tabs) {
      do {
        let inventory: WorktreeInventory
        if let common = tab.binding?.record.repositoryID {
          inventory = try GitWorktreeCatalog.read(commonDirectory: common)
        }
        else { inventory = try GitWorktreeCatalog.discover(at: URL(fileURLWithPath: tab.path)) }
        register(inventory)
        guard inventory.primary?.availability == .available else { continue }
        let target = tab.restoredRecord(in: inventory) { path in
          record(containing: URL(fileURLWithPath: path), in: inventory)
        }
        guard let target else {
          if let binding = tab.binding {
            let state = WorktreeTabState(sessionID: tab.id, binding: binding)
            if WorktreePolicy.removal(of: state, inventory: inventory,
                metadataExists: FileManager.default.fileExists(atPath: binding.record.privateDirectory),
                pathExists: FileManager.default.fileExists(atPath: binding.record.path)) == .close {
              confirmedRemovedOnRestore.insert(tab.id)
            }
          }
          continue
        }
        guard target.availability == .available else { continue }
        let directory = RepositorySession.validDirectory(tab.terminalDirectory)
          .flatMap { record(containing: $0, in: inventory)?.id == target.id ? $0.path : nil }
        candidates.append(.init(sessionID: tab.id,
            binding: .init(record: target, additionalSession: tab.binding?.additionalSession ?? false),
            terminalDirectory: directory))
      }
      catch { repoLogger.publicError("Worktree restore unavailable: \(error)") }
    }
    let plans = WorktreePolicy.restore(candidates, inventories: inventories)
    var restored: [UUID: NSWindow] = [:]
    for plan in plans {
      do {
        let document: RepoDocument
        if let existing = tabs.first(where: { $0.sessionID == plan.sessionID }) {
          document = existing
        }
        else if plan.binding.isPinnedPrimary, let existing = preferred(plan.binding.record.id),
                existing.worktreeBinding?.isPinnedPrimary == true {
          document = existing
        }
        else {
          document = try create(plan.binding.record, id: plan.sessionID,
              additional: plan.binding.additionalSession, display: true,
              directory: RepositorySession.validDirectory(plan.terminalDirectory))
        }
        if let window = document.windowControllers.first?.window {
          restored[plan.sessionID] = window
        }
      }
      catch { repoLogger.publicError("Worktree window restore failed: \(error)") }
    }
    // Rebuild each saved native group rather than grouping separate windows
    // merely because they happen to show the same repository.
    for group in saved.windows {
      let members = group.tabs.compactMap { restored[$0.id] }
      for window in members { window.tabGroup?.removeWindow(window) }
      guard let first = members.first else { continue }
      for window in members.dropFirst() { first.addTabbedWindow(window, ordered: .above) }
      if let native = first.tabGroup {
        for (index, window) in members.enumerated() { native.insertWindow(window, at: index) }
      }
      let selected = group.selectedTabID.flatMap { restored[$0] } ?? first
      selected.tabGroup?.selectedWindow = selected
      for window in members {
        (window.windowController as? HelmWindowController)?
          .prepareWindowPresentation(group.presentation, legacy: group.presentation == nil)
      }
      (selected.windowController as? HelmWindowController)?.restoreWindowPresentation()
    }
    if let id = saved.activeTabID, let window = restored[id] { window.makeKeyAndOrderFront(nil) }
    pinPrimaryTabs()
    return restored
  }

  func directoryChanged(_ directory: URL?, in source: RepoDocument)
  {
    guard !isTerminating, !source.worktreeRemovalPending,
          let directory, let binding = source.worktreeBinding else { return }
    do {
      let inventory = try GitWorktreeCatalog.discover(at: directory)
      guard inventory.repositoryID == binding.record.repositoryID,
            let target = record(containing: directory, in: inventory) else {
        source.windowController?.worktreeTransitionPending = true
        source.windowController?.window?.subtitle = "Terminal outside this worktree — Git changes paused: " + directory.path
        return
      }
      register(inventory)
      let currentPath = GitWorktreeCatalog.canonical(directory.path)
      guard target.availability == .available,
            currentPath == target.path || currentPath.hasPrefix(target.path + "/") else {
        source.windowController?.worktreeTransitionPending = true
        source.windowController?.window?.subtitle = "Worktree path unavailable — Git changes paused"
        return
      }
      guard target.id != binding.record.id else {
        source.terminalDirectoryURL = directory
        source.windowController?.worktreeTransitionPending = false
        source.windowController?.window?.subtitle = ""
        pendingDirectories[source.sessionID] = nil
        documents.sessions.scheduleSave()
        return
      }
      pendingDirectories[source.sessionID] = directory
      transfer(from: source, to: target, directory: directory)
    }
    catch {
      // Non-Git CWD is not a request to rebind Git operations to another folder.
      source.windowController?.worktreeTransitionPending = true
      source.windowController?.window?.subtitle = "Terminal outside this worktree — Git changes paused: " + directory.path
    }
  }

  func retryPending(_ document: RepoDocument)
  {
    guard !isTerminating, !isConfirmingTermination,
          tabs.contains(where: { $0 === document }) else { return }
    if let moved = pendingMoves[document.sessionID] { reloadMoved(document, as: moved); return }
    if let directory = pendingDirectories[document.sessionID] {
      directoryChanged(directory, in: document)
    }
    if removalRetry.contains(document.sessionID), let common = document.worktreeBinding?.record.repositoryID {
      scheduleRefresh(common)
    }
  }

  private func transfer(from source: RepoDocument, to target: WorktreeRecord,
                        directory: URL)
  {
    guard !transitioning, !isTerminating, !isConfirmingTermination,
          let sourceController = source.windowController else { return }
    let states = tabs.compactMap(state)
    guard let sourceState = state(source) else { return }
    let plan = WorktreePolicy.transition(from: sourceState, to: target, tabs: states)
    if plan == .deferred {
      sourceController.worktreeTransitionPending = true
      sourceController.window?.subtitle = "Terminal moved; waiting for the Git operation to finish"
      return
    }
    guard plan != .unavailable, plan != .unchanged else { return }
    transitioning = true
    defer { transitioning = false; pinPrimaryTabs(); documents.sessions.scheduleSave() }
    var created: RepoDocument?
    do {
      let destination: RepoDocument
      switch plan {
        case .useSession(let id):
          guard let existing = tabs.first(where: { $0.sessionID == id }) else { return }
          destination = existing
        case .create(let additional):
          destination = try create(target, additional: additional, display: false)
          created = destination
        default: return
      }
      guard let targetController = destination.windowController else {
        throw GitWorktreeCatalog.Failure.invalidInventory
      }
      let replacement = TerminalPanelViewController(
          workingDirectory: source.worktreeBinding!.record.path,
          agent: .terminal, automaticStart: false)
      try WorktreeTerminalTransfer.perform(from: sourceController,
          to: targetController, replacement: replacement)
      source.terminalDirectoryURL = nil
      destination.terminalDirectoryURL = directory
      let originalValid = inventories[target.repositoryID]?.records.contains {
        $0.id == source.worktreeBinding?.record.id && $0.availability == .available
      } == true
      sourceController.worktreeTransitionPending = !originalValid
      sourceController.window?.subtitle = originalValid ? "Terminal moved to " + target.folder :
          "Original worktree removed — terminal preserved in its destination tab"
      targetController.window?.subtitle = destination.worktreeBinding?.additionalSession == true
          ? "Additional terminal session — existing session preserved" : "Terminal session moved here"
      pendingDirectories[source.sessionID] = nil
      targetController.bindTerminalDirectoryObserver()
      destination.showWindows()
      sourceController.refreshWorktreePresentation()
      targetController.refreshWorktreePresentation()
      retryPending(source)
    }
    catch {
      // Preflight fails before either terminal changes owner. Keep live work.
      if let created { created.close() }
      sourceController.worktreeTransitionPending = true
      sourceController.window?.subtitle = "Terminal moved; original session preserved — retry from Worktrees"
    }
  }

  private func state(_ document: RepoDocument) -> WorktreeTabState?
  {
    guard let binding = document.worktreeBinding else { return nil }
    let controller = document.windowController
    return .init(sessionID: document.sessionID, binding: binding,
        terminalRunning: controller?.terminalIsRunning == true,
        operationBusy: controller?.transferIsBlocked == true || controller?.repoController?.queue.isBusy == true,
        dirty: (controller?.workspaceCountModel.counts.staged ?? 0) > 0 ||
               (controller?.workspaceCountModel.counts.unstaged ?? 0) > 0)
  }

  private func reloadMoved(_ source: RepoDocument, as record: WorktreeRecord)
  {
    guard !transitioning, !isTerminating, let old = source.windowController else { return }
    pendingMoves[source.sessionID] = record
    source.windowController?.worktreeTransitionPending = true
    guard !old.transferIsBlocked, !old.repoController.queue.isBusy else {
      old.window?.subtitle = "Worktree moved — waiting for the Git operation before reload"
      return
    }
    transitioning = true
    defer { transitioning = false; pinPrimaryTabs(); documents.sessions.scheduleSave() }
    var replacementDocument: RepoDocument?
    do {
      try documents.sessions.performLayoutChange {
        let selected = old.window?.isMainWindow == true
        let group = old.window?.tabGroup
        let index = old.window.flatMap { window in group?.windows.firstIndex(of: window) }
        let directory = old.terminalPanelController?.terminalController.reportedDirectory
          .flatMap { $0.path.hasPrefix(record.path + "/") || $0.path == record.path ? $0 : nil }
        let fresh = try create(record, id: source.sessionID,
            additional: source.worktreeBinding?.additionalSession ?? false,
            display: false, directory: directory)
        replacementDocument = fresh
        guard let target = fresh.windowController else { throw GitWorktreeCatalog.Failure.invalidInventory }
        let dormant = TerminalPanelViewController(workingDirectory: record.path,
                                                   agent: .terminal, automaticStart: false)
        try WorktreeTerminalTransfer.perform(from: old, to: target, replacement: dormant)
        if let index, let window = target.window { group?.insertWindow(window, at: index) }
        source.close()
        fresh.showWindows()
        if !selected { group?.selectedWindow?.makeKeyAndOrderFront(nil) }
        target.window?.subtitle = "Worktree moved — terminal session preserved"
        target.worktreeTransitionPending = false
        pendingMoves[source.sessionID] = nil
      }
    }
    catch {
      replacementDocument?.close()
      old.window?.subtitle = "Worktree moved — session retained; retry from Worktrees"
    }
  }

  private func record(containing directory: URL, in inventory: WorktreeInventory)
      -> WorktreeRecord? {
    GitWorktreeCatalog.locate(directory, in: inventory)
  }

  func existingWorktreeCount(for common: String) -> Int?
  {
    guard !inventoryRefreshFailures.contains(common) else { return nil }
    return inventories[common]?.records.filter { !$0.isPrimary }.count
  }

  private func register(_ inventory: WorktreeInventory)
  {
    inventories[inventory.repositoryID] = inventory
    inventoryRefreshFailures.remove(inventory.repositoryID)
    for document in tabs where document.worktreeBinding?.record.repositoryID == inventory.repositoryID {
      document.windowController?.refreshWorktreePresentation()
    }
    guard watchers[inventory.repositoryID] == nil else { return }
    let common = inventory.repositoryID
    watchers[common] = FileEventStream(path: common,
        excludePaths: [common + "/objects"], queue: .main) { [weak self] paths in
      guard paths.isEmpty || paths.contains(where: {
        $0.contains(common + "/worktrees") || $0.hasSuffix("/HEAD") ||
        $0.hasSuffix("/packed-refs") || $0.hasSuffix("/config")
      }) else { return }
      self?.scheduleRefresh(common)
    }
  }

  private func scheduleRefresh(_ common: String)
  {
    guard pendingRefresh.insert(common).inserted else { return }
    reader.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      let result = Result { try GitWorktreeCatalog.read(commonDirectory: common) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.pendingRefresh.remove(common)
        self.reconcile(common, result: result)
      }
    }
  }

  private func reconcile(_ common: String, result: Result<WorktreeInventory, Error>)
  {
    guard !isTerminating else { return }
    let inventory = try? result.get()
    if let inventory { register(inventory) }
    else {
      inventoryRefreshFailures.insert(common)
      for document in tabs where document.worktreeBinding?.record.repositoryID == common {
        document.windowController?.refreshWorktreePresentation()
      }
    }
    for document in tabs where document.worktreeBinding?.record.repositoryID == common {
      guard let tab = state(document) else { continue }
      // Explicit removal owns post-success closure; catalog events cannot
      // pre-close sessions while its Git result is still unknown.
      if removingWorktrees.contains(tab.binding.record.id) { continue }
      if let current = inventory?.records.first(where: { $0.id == tab.binding.record.id }) {
        if current.path != tab.binding.record.path {
          reloadMoved(document, as: current)
        }
        else {
          document.worktreeBinding?.record = current
          document.windowController?.refreshWorktreePresentation()
        }
      }
      let decision = WorktreePolicy.removal(of: tab, inventory: inventory,
          metadataExists: FileManager.default.fileExists(atPath: tab.binding.record.privateDirectory),
          pathExists: FileManager.default.fileExists(atPath: tab.binding.record.path))
      switch decision {
        case .close:
          removalRetry.remove(document.sessionID)
          document.close()
        case .unavailable:
          document.windowController?.worktreeTransitionPending = true
          document.windowController?.window?.subtitle = "Worktree unavailable — session retained"
        case .removedWithWork:
          removalRetry.insert(document.sessionID)
          document.windowController?.worktreeTransitionPending = true
          document.windowController?.window?.subtitle = "Worktree removed — terminal/work retained; close explicitly when safe"
        case .retain: break
      }
    }
    documents.sessions.retryUnavailableRestoration()
    documents.sessions.scheduleSave()
  }

  func populate(_ menu: NSMenu, for document: RepoDocument)
  {
    menu.removeAllItems()
    let title = NSMenuItem(title: "Worktrees", action: nil, keyEquivalent: "")
    title.image = HelmToolbarAppearance.symbol("rectangle.stack", description: "Worktrees")
    title.isEnabled = false
    title.isHidden = true
    menu.addItem(title) // Reserved pull-down title, never a real worktree.
    guard let binding = document.worktreeBinding else { return }
    let common = binding.record.repositoryID
    var inventory = inventories[common]
    var refreshFailed = false
    do {
      let refreshed = try GitWorktreeCatalog.read(commonDirectory: common)
      inventory = refreshed
      reconcile(common, result: .success(refreshed))
    }
    catch {
      refreshFailed = true
      repoLogger.publicError("Worktree menu refresh failed: \(error.localizedDescription)")
      let errorItem = NSMenuItem(title: "Unable to refresh worktrees", action: nil, keyEquivalent: "")
      errorItem.isEnabled = false
      errorItem.toolTip = error.localizedDescription
      menu.addItem(errorItem)
    }
    for record in inventory?.records ?? [binding.record] {
      let role = record.isPrimary ? "Primary checkout — " : ""
      let label = role + record.title + (record.isLocked ? " 🔒" : "")
      let item = NSMenuItem(title: label, action: #selector(openFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = record
      item.state = record.id == binding.record.id ? .on : .off
      item.isEnabled = record.availability == .available
      item.toolTip = record.path
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let new = NSMenuItem(title: "New Worktree…", action: #selector(newWorktreeFromMenu(_:)), keyEquivalent: "")
    new.target = self
    new.representedObject = document.sessionID
    new.isEnabled = !refreshFailed && !mutatingRepositories.contains(common)
    menu.addItem(new)
    let removalMenu = NSMenu(title: "Remove Worktree")
    removalMenu.autoenablesItems = false
    for record in inventory?.records.filter({ !$0.isPrimary }) ?? [] {
      let item = NSMenuItem(title: record.title + (record.isLocked ? " 🔒" : ""),
          action: #selector(removeWorktreeFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = WorktreeRemovalRequest(owner: document.sessionID, record: record)
      item.isEnabled = !refreshFailed && record.availability == .available &&
          !record.isLocked && !mutatingRepositories.contains(common)
      item.toolTip = "Remove a clean linked checkout. Idle tab closure requires confirmation; active or unknown sessions are protected. The branch is kept."
      removalMenu.addItem(item)
    }
    let remove = NSMenuItem(title: "Remove Worktree…", action: nil, keyEquivalent: "")
    remove.submenu = removalMenu
    remove.isEnabled = !removalMenu.items.isEmpty && !refreshFailed
    menu.addItem(remove)
    if pendingDirectories[document.sessionID] != nil {
      let retry = NSMenuItem(title: "Retry Moving This Terminal", action: #selector(retryFromMenu(_:)), keyEquivalent: "")
      retry.target = self; retry.representedObject = document
      menu.addItem(.separator()); menu.addItem(retry)
    }
    menu.addItem(.separator())
    let colorMenu = NSMenu(title: "Repository Color")
    let override = colorState.overrides[common]
    for index in -1..<Self.colors.count {
      let title = index < 0 ? "Automatic" : Self.colorNames[index]
      let item = NSMenuItem(title: title, action: #selector(changeColor(_:)), keyEquivalent: "")
      item.target = self; item.tag = index; item.representedObject = common
      var automatic = colorState
      automatic.overrides[common] = nil
      let sample = index < 0 ? Self.colors[automatic.index(for: common, count: Self.colors.count)] : Self.colors[index]
      item.image = Self.colorSwatch(sample, label: title)
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
      item.state = override == index || (index == -1 && override == nil) ? .on : .off
      colorMenu.addItem(item)
    }
    let color = NSMenuItem(title: "Repository Color", action: nil, keyEquivalent: "")
    color.submenu = colorMenu; menu.addItem(color)
  }

  @objc private func newWorktreeFromMenu(_ item: NSMenuItem)
  {
    guard let id = item.representedObject as? UUID,
          let document = tabs.first(where: { $0.sessionID == id }),
          let record = document.worktreeBinding?.record else { return }
    startWorktreeAction(.create, source: document, record: record)
  }

  @objc private func removeWorktreeFromMenu(_ item: NSMenuItem)
  {
    guard let request = item.representedObject as? WorktreeRemovalRequest,
          let document = tabs.first(where: { $0.sessionID == request.owner }) else { return }
    startWorktreeAction(.remove(request.record), source: document, record: request.record)
  }

  private func removalBlocker(_ record: WorktreeRecord) -> String?
  {
    if record.isPrimary { return "The primary checkout cannot be removed." }
    if record.isLocked { return "This worktree is locked. Unlock it explicitly before removal." }
    for document in tabs where document.worktreeBinding?.record.id == record.id {
      guard let controller = document.windowController else { continue }
      let ownRemoval = (controller.currentOperation as? WorktreeActionController)?
          .isRemoving(record.id) == true
      if document.closeDecisionPending || document.closeApproved ||
          (!ownRemoval && (controller.currentOperation != nil ||
                          controller.repoController.queue.isBusy)) {
        return "A tab is closing or has a Git operation in progress. Wait for it to finish before removing this worktree."
      }
      if let terminal = controller.terminalPanelController?.terminalController,
         !terminal.removalDirectoryIsInside(record.path) {
        return "A terminal directory differs from this checkout or cannot be verified. Wait for its worktree transition or explicitly close it first."
      }
      if controller.terminalPanelController?.terminalController.worktreeRemovalStamp == nil {
        return "A terminal has an agent, foreground/background child job, or activity that cannot be verified. Finish or explicitly close that session before removing this worktree."
      }
    }
    if tabs.contains(where: {
      guard $0.worktreeBinding?.record.id != record.id,
            $0.windowController?.terminalIsRunning == true,
            let path = $0.terminalDirectoryURL?.path else { return false }
      let directory = GitWorktreeCatalog.canonical(path)
      return directory == record.path || directory.hasPrefix(record.path + "/")
    }) { return "Another worktree's terminal is still using this checkout. Leave it before removal." }
    return nil
  }

  private func approveRemoval(_ record: WorktreeRecord) -> String?
  {
    if let blocker = removalBlocker(record) { return blocker }
    var approved: [UUID: RemovalSession] = [:]
    for document in tabs where document.worktreeBinding?.record.id == record.id {
      let terminal = document.windowController?.terminalPanelController?.terminalController
      guard let stamp = terminal?.worktreeRemovalStamp,
            let proof = terminal?.worktreeRemovalProof else {
        return "Terminal activity changed. Nothing was removed; try again when it is idle."
      }
      approved[document.sessionID] = .init(terminal: terminal, stamp: stamp, proof: proof,
          previousTransition: document.windowController?.worktreeTransitionPending == true)
    }
    removalSessions[record.id] = approved
    for document in tabs where approved[document.sessionID] != nil {
      document.worktreeRemovalPending = true
      document.windowController?.worktreeTransitionPending = true
      guard let window = document.windowController?.window else { continue }
      // Native modal sheets temporarily prevent new terminal input/Git actions
      // in every approved target tab while its removal is being decided.
      let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
          styleMask: [.titled], backing: .buffered, defer: false)
      panel.title = "Removing Worktree"
      let label = NSTextField(labelWithString: "Removing checkout; keeping its branch…")
      label.frame = NSRect(x: 20, y: 26, width: 310, height: 22)
      panel.contentView?.addSubview(label)
      removalSheets[record.id, default: []].append((window, panel))
      window.beginSheet(panel)
    }
    return nil
  }

  private func recheckRemoval(_ record: WorktreeRecord) -> String?
  {
    if let blocker = removalBlocker(record) { return blocker }
    guard let approved = removalSessions[record.id] else {
      return "Removal confirmation is no longer valid. Nothing was removed."
    }
    let current = tabs.filter { $0.worktreeBinding?.record.id == record.id }
    guard Set(current.map(\.sessionID)) == Set(approved.keys) else {
      return "The worktree's tabs changed after confirmation. Nothing was removed."
    }
    for document in current {
      guard let saved = approved[document.sessionID],
            let terminal = document.windowController?.terminalPanelController?.terminalController,
            terminal === saved.terminal,
            let stamp = terminal.worktreeRemovalStamp,
            stamp == saved.stamp || stamp == "stopped" else {
        return "A terminal changed or became busy after confirmation. Nothing was removed."
      }
    }
    return nil
  }

  private func finishRemoval(_ record: WorktreeRecord, succeeded: Bool)
  {
    for (window, panel) in removalSheets.removeValue(forKey: record.id) ?? [] {
      window.endSheet(panel)
    }
    let approved = removalSessions.removeValue(forKey: record.id) ?? [:]
    for document in tabs where approved[document.sessionID] != nil {
      guard let saved = approved[document.sessionID] else { continue }
      document.worktreeRemovalPending = false
      guard document.worktreeBinding?.record.id == record.id else { continue }
      if !succeeded {
        document.windowController?.worktreeTransitionPending = saved.previousTransition
        continue
      }
      // The checkout is now gone: use process identity/activity, NOT cwd/stat.
      let terminal = document.windowController?.terminalPanelController?.terminalController
      let stamp = terminal?.worktreeRemovalStamp
      if terminal === saved.terminal, stamp != nil,
         stamp == saved.stamp || stamp == "stopped" {
        document.closeApproved = true
        document.close() // Explicit confirmation already authorized idle closure.
      }
      else {
        document.windowController?.worktreeTransitionPending = true
        document.windowController?.window?.subtitle = "Worktree removed — session changed; work retained. Close explicitly when safe."
        removalRetry.insert(document.sessionID)
      }
    }
  }

  private func startWorktreeAction(_ action: WorktreeActionController.Action,
                                   source: RepoDocument, record: WorktreeRecord)
  {
    guard let controller = source.windowController,
          mutatingRepositories.insert(record.repositoryID).inserted else { return }
    let removalID: String?
    if case .remove = action { removalID = record.id }
    else { removalID = nil }
    if let removalID { removingWorktrees.insert(removalID) }
    let operation = WorktreeActionController(windowController: controller,
        action: action, source: record)
    operation.removalBlocker = { [weak self] target in self?.removalBlocker(target) }
    operation.removalConfirmed = { [weak self, weak operation] target in
      guard let self, let operation else { return "Worktree controller unavailable." }
      if let blocker = self.approveRemoval(target) { return blocker }
      let proofs = self.removalSessions[target.id]?.values.map(\.proof) ?? []
      operation.removalProcessRecheck = {
        proofs.allSatisfy { $0.stillAppearsIdle() } ? nil :
          "A terminal became busy or its process identity changed. Nothing was removed."
      }
      return nil
    }
    operation.removalRecheck = { [weak self] target in
      self?.recheckRemoval(target) ?? (self == nil ? "Worktree controller unavailable." : nil)
    }
    operation.finished = { [weak self, weak source, weak operation] result, directory in
      guard let self else { return }
      if removalID != nil { self.finishRemoval(record, succeeded: result == .success) }
      self.mutatingRepositories.remove(record.repositoryID)
      if let removalID { self.removingWorktrees.remove(removalID) }
      self.scheduleRefresh(record.repositoryID)
      if result == .success, let directory, let source,
         !source.closeApproved, operation?.canceled != true, !self.isTerminating {
        do { _ = try self.open(at: URL(fileURLWithPath: directory)) }
        catch { source.windowController?.showAlert(nsError: NSError(domain: "HelmWorktrees", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The worktree was created at \(directory), but could not be opened: \(error.localizedDescription)"])) }
      }
    }
    if controller.startOperation(factory: { operation }) == nil {
      mutatingRepositories.remove(record.repositoryID)
      if let removalID { removingWorktrees.remove(removalID) }
    }
  }

  func color(for repositoryID: String) -> NSColor
  {
    let previous = colorState
    let index = colorState.index(for: repositoryID, count: Self.colors.count)
    if colorStateNeedsSave || previous != colorState { saveColorState() }
    return Self.colors[index]
  }
  private func saveColorState()
  {
    if let data = try? JSONEncoder().encode(colorState) {
      defaults.set(data, forKey: Self.colorStateKey)
      colorStateNeedsSave = false
    }
  }

  private static func colorSwatch(_ color: NSColor, label: String) -> NSImage
  {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      color.setFill()
      NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = label + " color sample"
    return image
  }

  @objc private func openFromMenu(_ item: NSMenuItem)
  {
    guard let record = item.representedObject as? WorktreeRecord else { return }
    do { _ = try open(at: URL(fileURLWithPath: record.path)) }
    catch { NSApp.presentError(error) }
  }
  @objc private func retryFromMenu(_ item: NSMenuItem)
  {
    if let document = item.representedObject as? RepoDocument { retryPending(document) }
  }
  @objc private func changeColor(_ item: NSMenuItem)
  {
    guard let common = item.representedObject as? String else { return }
    colorState.overrides[common] = item.tag >= 0 ? item.tag : nil
    saveColorState()
    for document in tabs where document.worktreeBinding?.record.repositoryID == common {
      document.windowController?.refreshWorktreePresentation()
    }
    NotificationCenter.default.post(name: .sidebarRepositoryColorDidChange, object: common)
  }
}
