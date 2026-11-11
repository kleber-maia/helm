import XCTest

final class RepositorySessionTests: XCTestCase
{
  private func record(_ primary: Bool) -> WorktreeRecord {
    .init(id: primary ? "/repo/.git" : "/repo/.git/worktrees/feature", repositoryID: "/repo/.git",
          path: primary ? "/trees/root" : "/trees/feature", branch: primary ? "trunk" : "main",
          head: String(repeating: "a", count: 40), isPrimary: primary, availability: .available)
  }
  func testVersionOnePayloadDecodesWithoutBindingOrCWD() throws {
    let id = UUID()
    let text = "{\"version\":1,\"windows\":[{\"tabs\":[{\"id\":\"\(id)\",\"path\":\"/trees/root\"}],\"selectedTabID\":\"\(id)\"}],\"activeTabID\":\"\(id)\"}"
    let saved = try JSONDecoder().decode(RepositorySession.self, from: Data(text.utf8))
    XCTAssertEqual(saved.windows[0].tabs[0].id, id)
    XCTAssertNil(saved.windows[0].tabs[0].binding); XCTAssertNil(saved.windows[0].tabs[0].terminalDirectory)
  }
  func testRepeatedRoundTripPreservesBindingOrderSelectedTabAndCWD() throws {
    let a = UUID(), b = UUID()
    var saved = RepositorySession(windows: [.init(tabs: [
      .init(id: a, path: "/trees/root", binding: .init(record: record(true))),
      .init(id: b, path: "/trees/feature", terminalDirectory: "/trees/feature/src", binding: .init(record: record(false)))
    ], selectedTabID: b)], activeTabID: b)
    let original = saved
    for _ in 0..<20 { saved = try JSONDecoder().decode(RepositorySession.self, from: JSONEncoder().encode(saved)) }
    XCTAssertEqual(saved, original)
  }
  func testRestoreInsertsMissingPrimaryAndKeepsLinkedUUID() {
    let linked = UUID(), primary = UUID(), inventory = WorktreeInventory(repositoryID: "/repo/.git", records: [record(true), record(false)])
    let restored = WorktreePolicy.restore([.init(sessionID: linked, binding: .init(record: record(false)), terminalDirectory: nil)],
        inventories: [inventory.repositoryID: inventory], makeID: { primary })
    XCTAssertEqual(restored.map(\.sessionID), [primary, linked])
    XCTAssertTrue(restored[0].binding.isPinnedPrimary)
  }
  func testRestorePreservesPrimaryUUIDAndNamesLegacyDuplicatesExplicitly() {
    let id = UUID(), extra = UUID(), r = record(true)
    let items = [id, extra].map { WorktreeRestoreItem(sessionID: $0, binding: .init(record: r), terminalDirectory: nil) }
    let restored = WorktreePolicy.restore(items, inventories: [r.repositoryID: .init(repositoryID: r.repositoryID, records: [r])])
    XCTAssertEqual(restored.map(\.sessionID), [id, extra])
    XCTAssertTrue(restored[0].binding.isPinnedPrimary); XCTAssertTrue(restored[1].binding.additionalSession)
  }
  func testStoreRejectsCorruptionAndFutureVersionWithoutErasingData() throws {
    let name = "helm-worktree-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: backup) }
    let store = RepositorySessionStore(defaults: defaults, backupRoot: backup)
    for raw in [Data("broken".utf8), Data("{\"version\":99,\"windows\":[]}".utf8)] {
      defaults.set(raw, forKey: RepositorySessionStore.key)
      XCTAssertNil(store.load()); XCTAssertEqual(defaults.data(forKey: RepositorySessionStore.key), raw)
    }
  }
  func testEmptyCloseSnapshotPreservesLastNonemptyLayout() {
    let name = "helm-worktree-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: backup) }
    let store = RepositorySessionStore(defaults: defaults, backupRoot: backup), id = UUID()
    let saved = RepositorySession(windows: [.init(tabs: [.init(id: id, path: "/trees/root")], selectedTabID: id)], activeTabID: id)
    store.save(saved); store.save(.init(windows: [], activeTabID: nil))
    XCTAssertEqual(store.load(), saved)
  }
  func testColorsAreStableDistinctWhileAvailableAndOverridable() throws {
    var colors = RepositoryColorAssignments()
    let a = colors.index(for: "/repo/a/.git", count: 6)
    let b = colors.index(for: "/repo/b/.git", count: 6)
    XCTAssertNotEqual(a, b)
    colors = try JSONDecoder().decode(RepositoryColorAssignments.self, from: JSONEncoder().encode(colors))
    XCTAssertEqual(colors.index(for: "/repo/a/.git", count: 6), a)
    colors.overrides["/repo/a/.git"] = 4
    XCTAssertEqual(colors.index(for: "/repo/a/.git", count: 6), 4)
    colors.overrides["/repo/a/.git"] = nil
    XCTAssertEqual(colors.index(for: "/repo/a/.git", count: 6), a)
  }
  func testInvalidStoredTerminalDirectoriesDoNotBecomeLaunchPaths() {
    XCTAssertNil(RepositorySession.validDirectory("relative"))
    XCTAssertNil(RepositorySession.validDirectory("/this/path/does/not/exist"))
    XCTAssertNil(RepositorySession.localTerminalDirectory("file://remote.invalid/tmp"))
    XCTAssertNil(RepositorySession.localTerminalDirectory("https://example.invalid/tmp"))
  }
  func testUnavailableSavedEntrySurvivesRepeatedPartialRestoreAndQuit() throws {
    let a = UUID(), missing = UUID(), p = record(true), linked = record(false)
    let saved = RepositorySession(windows: [.init(tabs: [
      .init(id: a, path: p.path, binding: .init(record: p)),
      .init(id: missing, path: linked.path, terminalDirectory: linked.path + "/src", binding: .init(record: linked))
    ], selectedTabID: missing)], activeTabID: missing)
    let visible = RepositorySession(windows: [.init(tabs: [saved.windows[0].tabs[0]], selectedTabID: a)], activeTabID: a)
    var previous = saved
    for _ in 0..<10 {
      previous = visible.retaining(previous, ids: [missing])
      previous = try JSONDecoder().decode(RepositorySession.self, from: JSONEncoder().encode(previous))
      XCTAssertEqual(previous.windows[0].tabs.map(\.id), [a, missing])
      XCTAssertEqual(previous.windows[0].tabs[1].terminalDirectory, linked.path + "/src")
      XCTAssertEqual(previous.windows[0].tabs[1].binding?.record.id, linked.id)
    }
  }
  func testRetainingUnavailableDoesNotResurrectExplicitlyClosedEntry() {
    let a = UUID(), missing = UUID(), closed = UUID()
    let tabs = [a, missing, closed].map {
      RepositorySession.Tab(id: $0, path: "/trees/root", binding: .init(record: record(true)))
    }
    let saved = RepositorySession(windows: [.init(tabs: tabs, selectedTabID: a)], activeTabID: a)
    let visible = RepositorySession(windows: [.init(tabs: [tabs[0]], selectedTabID: a)], activeTabID: a)
    XCTAssertEqual(visible.retaining(saved, ids: [missing]).windows[0].tabs.map(\.id), [a, missing])
  }
  func testEntireUnavailableFamilyRemainsRecoverableWhenNoWindowsOpen() {
    let id = UUID(), tab = RepositorySession.Tab(id: id, path: "/offline/root", binding: .init(record: record(true)))
    let saved = RepositorySession(windows: [.init(tabs: [tab], selectedTabID: id)], activeTabID: id)
    let empty = RepositorySession(windows: [], activeTabID: nil)
    XCTAssertEqual(empty.retaining(saved, ids: [id]), saved)
  }
  func testColorAllocatorAvoidsDefaultHashCollisionWhenPaletteHasSpace() {
    var colors = RepositoryColorAssignments()
    let first = "/repo/0/.git"
    let start = WorktreePolicy.colorIndex(repositoryID: first, paletteCount: 6)
    let collision = (1...100).map { "/repo/\($0)/.git" }.first {
      WorktreePolicy.colorIndex(repositoryID: $0, paletteCount: 6) == start
    }!
    XCTAssertNotEqual(colors.index(for: first, count: 6), colors.index(for: collision, count: 6))
  }

  func testExplicitRecoveryReusesSavedUUIDAfterWorktreeMove() {
    let id = UUID(); let old = record(false)
    let saved = RepositorySession(windows: [.init(tabs: [
      .init(id: id, path: old.path, binding: .init(record: old))
    ], selectedTabID: id)], activeTabID: id)
    var moved = old; moved.path = "/trees/moved"
    XCTAssertEqual(saved.recoverableTab(for: moved, ids: [id])?.id, id)
    XCTAssertNil(saved.recoverableTab(for: moved, ids: []))
  }
  func testNewMetadataIncarnationCannotClaimUnavailableSavedSession() {
    let id = UUID(), old = record(false)
    let saved = RepositorySession(windows: [.init(tabs: [
      .init(id: id, path: old.path, binding: .init(record: old))
    ], selectedTabID: id)], activeTabID: id)
    var recreated = old; recreated.id += "#new-incarnation"
    XCTAssertNil(saved.recoverableTab(for: recreated, ids: [id]))
  }

  func testBoundRestoreNeverAdoptsRecreatedTreeAtSamePath() {
    let old = record(false)
    var replacement = old; replacement.id += "#new"
    let tab = RepositorySession.Tab(id: UUID(), path: old.path, binding: .init(record: old))
    let inventory = WorktreeInventory(repositoryID: old.repositoryID, records: [replacement])
    var lookupCalled = false
    XCTAssertNil(tab.restoredRecord(in: inventory) { _ in lookupCalled = true; return replacement })
    XCTAssertFalse(lookupCalled)
    let legacy = RepositorySession.Tab(id: UUID(), path: old.path)
    XCTAssertEqual(legacy.restoredRecord(in: inventory) { _ in replacement }, replacement)
  }
  func testBoundRestoreFindsMovedTreeByIdentity() {
    let old = record(false)
    var moved = old; moved.path = "/trees/moved"
    let tab = RepositorySession.Tab(id: UUID(), path: old.path, binding: .init(record: old))
    XCTAssertEqual(tab.restoredRecord(in: .init(repositoryID: old.repositoryID, records: [moved])) { _ in nil }, moved)
  }
  func testSidebarLegacyUpgradePreservesSubsequentNarrowChoice() {
    var state = RepositorySession.Window.Presentation(normalFrame: "frame", sidebarWidth: 180)
    XCTAssertEqual(state.restoredSidebarWidth(resolved: 300), 240)
    state.sidebarPolicyVersion = 1
    XCTAssertEqual(state.restoredSidebarWidth(resolved: 300), 180)
    state.sidebarPolicyVersion = nil; state.sidebarWidth = 245
    XCTAssertEqual(state.restoredSidebarWidth(resolved: 180), 245)
  }
  func testWindowGroupModesFramesAndWidthsRoundTrip() throws {
    let a = UUID(), b = UUID()
    let original = RepositorySession(windows: [
      .init(tabs: [.init(id: a, path: "/trees/root")], selectedTabID: a,
          presentation: .init(normalFrame: "{{10,20},{960,800}}", windowedFrame: "{{0,0},{1500,900}}", mode: .fullScreen, windowedMode: .zoomed, sidebarWidth: 300, sidebarPolicyVersion: 1, sidebarHidden: false)),
      .init(tabs: [.init(id: b, path: "/trees/other")], selectedTabID: b,
          presentation: .init(normalFrame: "{{100,100},{1000,700}}", mode: .normal, sidebarWidth: 180, sidebarPolicyVersion: 1, sidebarHidden: true))
    ], activeTabID: a)
    XCTAssertEqual(try JSONDecoder().decode(RepositorySession.self, from: JSONEncoder().encode(original)), original)
  }
  func testFailedSessionBackupRetainsOriginalBytesAndReportsFailure() throws {
    let name = "helm-session-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("blocked".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), old = RepositorySession(version: 2, windows: [.init(tabs: [.init(id: id, path: "/trees/root")], selectedTabID: id)], activeTabID: id)
    let raw = try JSONEncoder().encode(old)
    defaults.set(raw, forKey: RepositorySessionStore.key)
    let store = RepositorySessionStore(defaults: defaults, backupRoot: root)
    var changed = old; changed.version = 3
    XCTAssertFalse(store.save(changed))
    XCTAssertEqual(defaults.data(forKey: RepositorySessionStore.key), raw)
    XCTAssertFalse(store.failure?.isEmpty ?? true)
  }

}
