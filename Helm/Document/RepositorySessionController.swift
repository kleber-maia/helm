import AppKit

/// Owns Helm's tab layout independently of macOS's optional window restoration.
@MainActor
final class RepositorySessionController
{
  private unowned let documents: HelmDocumentController
  private let store = RepositorySessionStore()
  private var attemptedRestore = false
  private var savedForRecovery: RepositorySession?
  private var unrestoredIDs = Set<UUID>()
  private var restoring = false
  private var terminating = false
  var isRestoringLayout: Bool { restoring }
  var isTerminating: Bool { terminating }
  private var reportedFailure: String?
  private var saveScheduled = false
  private var closingIDs = Set<UUID>()
  private var beforeClosing: RepositorySession?
  private var observers: [NSObjectProtocol] = []
  private var windowObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
  private var groupObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

  init(documents: HelmDocumentController)
  {
    self.documents = documents
    let token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeMainNotification,
        object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleSave() }
    }
    observers.append(token)
  }

  deinit
  {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  @discardableResult
  func restoreIfNeeded() -> Bool
  {
    guard !attemptedRestore
    else { return !documents.documents.isEmpty }
    attemptedRestore = true

    guard documents.documents.isEmpty,
          let saved = store.load()
    else { reportFailure(); return !documents.documents.isEmpty }

    restoring = true
    savedForRecovery = saved
    let restored = documents.worktrees.restore(saved)
    unrestoredIDs = Set(saved.windows.flatMap(\.tabs).map(\.id))
      .subtracting(restored.keys).subtracting(documents.worktrees.confirmedRemovedOnRestore)
    restoring = false
    observeTabGroups()
    return !restored.isEmpty
  }

  func willClose(_ document: RepoDocument)
  {
    guard !restoring, !terminating else { return }
    if beforeClosing == nil { beforeClosing = snapshot() }
    closingIDs.insert(document.sessionID)
    scheduleSave()
  }

  func prepareForTermination()
  {
    guard !terminating else { return }
    saveCurrentSession()
    terminating = true
  }

  func cancelTerminationPreparation()
  {
    terminating = false
    scheduleSave()
  }

  func recoverableTab(for record: WorktreeRecord) -> RepositorySession.Tab?
  {
    savedForRecovery?.recoverableTab(for: record, ids: unrestoredIDs)
  }

  func didRecover(_ id: UUID)
  {
    unrestoredIDs.remove(id)
  }

  func retryUnavailableRestoration()
  {
    guard !restoring, !terminating, !unrestoredIDs.isEmpty,
          let saved = savedForRecovery else { return }
    let windows = saved.windows.compactMap { group -> RepositorySession.Window? in
      let tabs = group.tabs.filter { unrestoredIDs.contains($0.id) }
      return tabs.isEmpty ? nil : .init(tabs: tabs, selectedTabID: nil, presentation: group.presentation)
    }
    let selected = NSApp.mainWindow
    restoring = true
    let restored = documents.worktrees.restore(.init(windows: windows, activeTabID: nil))
    unrestoredIDs.subtract(restored.keys)
    unrestoredIDs.subtract(documents.worktrees.confirmedRemovedOnRestore)
    restoring = false
    selected?.makeKeyAndOrderFront(nil)
    observeTabGroups()
    scheduleSave()
  }

  func performLayoutChange(_ body: () throws -> Void) rethrows
  {
    let previous = restoring
    restoring = true
    defer { restoring = previous; scheduleSave() }
    try body()
  }

  func scheduleSave()
  {
    guard !restoring, !terminating, !saveScheduled else { return }
    saveScheduled = true
    // A native Close Window can close several tabs in the same event. Save
    // once after the group has closed, retaining its last nonempty layout.
    DispatchQueue.main.async { [weak self] in self?.saveCurrentSession() }
  }

  private func saveCurrentSession()
  {
    saveScheduled = false
    guard !restoring, !terminating else { return }
    documents.worktrees.pinPrimaryTabs()
    let visible = snapshot()
    let base = visible.isEmpty ? (beforeClosing ?? visible) : visible
    let current = savedForRecovery.map { base.retaining($0, ids: unrestoredIDs) } ?? base
    if !current.isEmpty {
      store.save(current)
    }
    else if let beforeClosing {
      store.save(beforeClosing)
    }
    reportFailure()
    closingIDs.removeAll()
    beforeClosing = nil
    observeTabGroups()
  }

  private func snapshot() -> RepositorySession
  {
    let entries = documents.documents.compactMap { $0 as? RepoDocument }
      .filter { !closingIDs.contains($0.sessionID) }
    let windows = entries.compactMap { $0.windowControllers.first?.window }
    let byWindow = Dictionary(uniqueKeysWithValues: entries.compactMap {
      document -> (ObjectIdentifier, RepositorySession.Tab)? in
      guard let window = document.windowControllers.first?.window,
            let url = document.fileURL else { return nil }
      return (ObjectIdentifier(window), .init(id: document.sessionID,
          path: url.path,
          terminalDirectory: document.terminalDirectoryURL?.path,
          binding: document.worktreeBinding))
    })
    var seen = Set<UUID>()
    var groups: [RepositorySession.Window] = []
    for window in NSApp.orderedWindows + windows {
      guard let tab = byWindow[ObjectIdentifier(window)],
            !seen.contains(tab.id) else { continue }
      let members = window.tabGroup?.windows ?? [window]
      let tabs = members.compactMap { byWindow[ObjectIdentifier($0)] }
      tabs.forEach { seen.insert($0.id) }
      let selected = window.tabGroup?.selectedWindow ?? window
      groups.append(.init(tabs: tabs,
          selectedTabID: byWindow[ObjectIdentifier(selected)]?.id,
          presentation: (selected.windowController as? HelmWindowController)?.captureWindowPresentation()))
    }
    let active = NSApp.mainWindow.flatMap { byWindow[ObjectIdentifier($0)]?.id }
    return .init(windows: groups, activeTabID: active)
  }

  private func reportFailure()
  {
    guard let message = store.failure, message != reportedFailure else { return }
    reportedFailure = message
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "Window layout could not be saved or restored"
      alert.informativeText = message
      alert.runModal()
    }
  }

  private func observeTabGroups()
  {
    let windows = documents.documents.compactMap {
      $0.windowControllers.first?.window
    }
    let windowIDs = Set(windows.map(ObjectIdentifier.init))
    windowObservations = windowObservations.filter { windowIDs.contains($0.key) }
    for window in windows where windowObservations[ObjectIdentifier(window)] == nil {
      windowObservations[ObjectIdentifier(window)] = window.observe(\.tabGroup) {
        [weak self] _, _ in
        MainActor.assumeIsolated { self?.scheduleSave() }
      }
    }
    let groups = windows.compactMap(\.tabGroup)
    let groupIDs = Set(groups.map(ObjectIdentifier.init))
    groupObservations = groupObservations.filter { groupIDs.contains($0.key) }
    for group in groups where groupObservations[ObjectIdentifier(group)] == nil {
      groupObservations[ObjectIdentifier(group)] = [
        group.observe(\.windows) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.scheduleSave() }
        },
        group.observe(\.selectedWindow) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.scheduleSave() }
        }
      ]
    }
  }
}
