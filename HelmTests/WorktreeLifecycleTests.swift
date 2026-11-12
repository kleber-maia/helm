import XCTest

final class WorktreeLifecycleTests: XCTestCase
{
  private let common = "/repositories/project/.git"
  private func record(_ name: String = "feature", primary: Bool = false) -> WorktreeRecord {
    .init(id: primary ? common : common + "/worktrees/" + name,
        repositoryID: common, path: "/trees/" + name, branch: primary ? "trunk" : name,
        head: String(repeating: "a", count: 40), isPrimary: primary,
        availability: .available)
  }
  private func tab(_ record: WorktreeRecord) -> WorktreeTabState {
    .init(sessionID: UUID(), binding: .init(record: record))
  }
  func testNormalOpenPrefersCanonicalSessionInsteadOfAdditionalTerminal() {
    let r = record(); var extra = tab(r); extra.binding.additionalSession = true
    let normal = tab(r)
    XCTAssertEqual(WorktreePolicy.preferred(r.id, in: [extra, normal]), normal.sessionID)
  }
  func testPrimaryRoleIsNotTheMainBranch() {
    let primary = record("checkout", primary: true), linked = record("main")
    XCTAssertEqual(primary.branch, "trunk"); XCTAssertTrue(primary.isPrimary)
    XCTAssertEqual(linked.branch, "main"); XCTAssertFalse(linked.isPrimary)
  }
  func testPrimaryCurrentAndUnassignedBranchesRemainUsable() {
    let owned: Set<String> = ["refs/heads/main"]
    for ref in ["refs/heads/trunk", "refs/heads/unassigned"] {
      XCTAssertTrue(WorktreeBranchPolicy.isVisible(ref, current: "refs/heads/trunk", primary: true))
      XCTAssertFalse(WorktreeBranchPolicy.isDisabled(ref, primary: true, linkedRefs: owned))
      XCTAssertTrue(WorktreeBranchPolicy.allowsSelection(ref, current: "refs/heads/trunk",
          primary: true, linkedRefs: owned))
    }
    XCTAssertTrue(WorktreeBranchPolicy.isVisible("refs/heads/main", current: "refs/heads/trunk", primary: true))
    XCTAssertTrue(WorktreeBranchPolicy.isDisabled("refs/heads/main", primary: true, linkedRefs: owned))
    XCTAssertFalse(WorktreeBranchPolicy.allowsSelection("refs/heads/main", current: "refs/heads/trunk",
        primary: true, linkedRefs: owned))
  }

  func testRemoteTrackingRefDoesNotCollideWithLinkedLocalBranch() {
    let owned: Set<String> = ["refs/heads/feature/owned"]
    XCTAssertTrue(WorktreeBranchPolicy.isDisabled("refs/heads/feature/owned", primary: true, linkedRefs: owned))
    XCTAssertFalse(WorktreeBranchPolicy.isDisabled("refs/remotes/origin/feature/owned", primary: true, linkedRefs: owned))
    XCTAssertFalse(WorktreeBranchPolicy.isDisabled("refs/heads/owned", primary: true, linkedRefs: owned))
  }

  func testLinkedVisibilityAndSelectionFollowCurrentHEADIncludingDetached() {
    let old = "refs/heads/feature/old", new = "refs/heads/feature/new"
    let owned: Set<String> = [old, new]
    XCTAssertTrue(WorktreeBranchPolicy.allowsSelection(old, current: old, primary: false, linkedRefs: owned))
    XCTAssertFalse(WorktreeBranchPolicy.isVisible(new, current: old, primary: false))
    XCTAssertFalse(WorktreeBranchPolicy.allowsSelection(old, current: new, primary: false, linkedRefs: owned))
    XCTAssertTrue(WorktreeBranchPolicy.allowsSelection(new, current: new, primary: false, linkedRefs: owned))
    for ref in [old, new] {
      XCTAssertFalse(WorktreeBranchPolicy.isVisible(ref, current: nil, primary: false))
      XCTAssertFalse(WorktreeBranchPolicy.allowsSelection(ref, current: nil, primary: false, linkedRefs: owned))
    }
  }

  func testPrimaryOrderingPreservesOtherSessionsAndIdentities() {
    let linked = tab(record()), primary = tab(record("checkout", primary: true))
    let another = tab(record("other"))
    XCTAssertEqual(WorktreePolicy.primaryFirst([linked, primary, another]).map(\.sessionID),
                   [primary.sessionID, linked.sessionID, another.sessionID])
  }
  func testInventoryFailureNeverConfirmsRemoval() {
    XCTAssertEqual(WorktreePolicy.removal(of: tab(record()), inventory: nil,
        metadataExists: false, pathExists: false), .unavailable)
  }
  func testTemporarilyMissingRegisteredWorktreeIsRetained() {
    var r = record(); r.availability = .unavailable
    XCTAssertEqual(WorktreePolicy.removal(of: tab(r),
        inventory: .init(repositoryID: common, records: [r]),
        metadataExists: true, pathExists: false), .unavailable)
  }
  func testUnregisteredExistingFilesAreNeverAutoClosed() {
    XCTAssertEqual(WorktreePolicy.removal(of: tab(record()),
        inventory: .init(repositoryID: common, records: []),
        metadataExists: false, pathExists: true), .unavailable)
  }
  func testMetadataStillPresentPreventsRemoval() {
    XCTAssertEqual(WorktreePolicy.removal(of: tab(record()),
        inventory: .init(repositoryID: common, records: []),
        metadataExists: true, pathExists: false), .unavailable)
  }
  func testConfirmedRemovalClosesOnlyAnIdleCleanSession() {
    XCTAssertEqual(WorktreePolicy.removal(of: tab(record()),
        inventory: .init(repositoryID: common, records: []),
        metadataExists: false, pathExists: false), .close)
  }
  func testRunningTerminalDirtyOrBusyStateRetainsRemovedSession() {
    for kind in 0..<3 {
      var t = tab(record())
      t.terminalRunning = kind == 0; t.operationBusy = kind == 1; t.dirty = kind == 2
      XCTAssertEqual(WorktreePolicy.removal(of: t,
          inventory: .init(repositoryID: common, records: []),
          metadataExists: false, pathExists: false), .removedWithWork)
    }
  }
  func testPrimaryNeverAutoClosesOnMissingInventoryEntry() {
    XCTAssertEqual(WorktreePolicy.removal(of: tab(record("checkout", primary: true)),
        inventory: .init(repositoryID: common, records: []),
        metadataExists: false, pathExists: false), .unavailable)
  }
  func testCWDWithinCurrentWorktreeDoesNotCreateATab() {
    let t = tab(record())
    XCTAssertEqual(WorktreePolicy.transition(from: t, to: t.binding.record, tabs: [t]), .unchanged)
  }
  func testBusySourceDefersWithoutReplacingTerminal() {
    var t = tab(record("checkout", primary: true)); t.operationBusy = true
    XCTAssertEqual(WorktreePolicy.transition(from: t, to: record(), tabs: [t]), .deferred)
  }
  func testVacantDestinationIsReused() {
    let source = tab(record("checkout", primary: true)), target = tab(record())
    XCTAssertEqual(WorktreePolicy.transition(from: source, to: target.binding.record,
        tabs: [source, target]), .useSession(target.sessionID))
  }
  func testOccupiedDestinationCreatesAdditionalSessionToPreserveBothPTYs() {
    let source = tab(record("checkout", primary: true)); var target = tab(record())
    target.terminalRunning = true
    XCTAssertEqual(WorktreePolicy.transition(from: source, to: target.binding.record,
        tabs: [source, target]), .create(additional: true))
  }
  func testForeignOrUnavailableDestinationIsNotSilentlyRebound() {
    let source = tab(record("checkout", primary: true)); var target = record()
    target.repositoryID = "/other/.git"
    XCTAssertEqual(WorktreePolicy.transition(from: source, to: target, tabs: [source]), .unavailable)
    target = record(); target.availability = .unavailable
    XCTAssertEqual(WorktreePolicy.transition(from: source, to: target, tabs: [source]), .unavailable)
  }
  func testCloseCancelAndApprovedQuitDecisions() {
    XCTAssertEqual(WorktreeClosePolicy.decision(runningTerminal: true, busyOperation: false), .confirm)
    XCTAssertEqual(WorktreeClosePolicy.decision(runningTerminal: true, busyOperation: false, confirmation: false), .cancel)
    XCTAssertEqual(WorktreeClosePolicy.decision(runningTerminal: true, busyOperation: false, confirmation: true), .allow)
    XCTAssertEqual(WorktreeClosePolicy.decision(runningTerminal: true, busyOperation: true, terminationApproved: true), .allow)
    XCTAssertEqual(WorktreeClosePolicy.decision(runningTerminal: false, busyOperation: false), .allow)
  }

  @MainActor final class Terminal {
    let pid: Int; var output = "retained output"; var stopCalls = 0
    init(_ pid: Int) { self.pid = pid }
  }
  @MainActor final class Host: WorktreeTerminalHost {
    var terminalForTransfer: Terminal
    var transferIsBlocked = false
    var replacements = 0
    var terminalIsRunning: Bool { terminalForTransfer.pid != 0 }
    init(_ terminal: Terminal) { terminalForTransfer = terminal }
    func replaceTerminalForTransfer(_ terminal: Terminal) {
      terminalForTransfer = terminal; replacements += 1
    }
  }
  @MainActor func testTransferPreservesExactControllerPIDAndOutput() throws {
    let live = Terminal(42), source = Host(Terminal(0)), target = Host(Terminal(0))
    source.terminalForTransfer = live
    let dormant = Terminal(0)
    try WorktreeTerminalTransfer.perform(from: source, to: target, replacement: dormant)
    XCTAssertTrue(target.terminalForTransfer === live)
    XCTAssertTrue(source.terminalForTransfer === dormant)
    XCTAssertEqual(target.terminalForTransfer.pid, 42)
    XCTAssertEqual(target.terminalForTransfer.output, "retained output")
    XCTAssertEqual(live.stopCalls, 0)
  }
  @MainActor func testOccupiedTargetFailureLeavesBothSessionsIntact() {
    let a = Terminal(1), b = Terminal(2), source = Host(a), target = Host(b)
    XCTAssertThrowsError(try WorktreeTerminalTransfer.perform(from: source, to: target,
        replacement: Terminal(0)))
    XCTAssertTrue(source.terminalForTransfer === a); XCTAssertTrue(target.terminalForTransfer === b)
    XCTAssertEqual(source.replacements + target.replacements, 0)
    XCTAssertEqual(a.stopCalls + b.stopCalls, 0)
  }
  @MainActor func testBusySourceAndDestinationFailuresAreAtomic() {
    for blockedSource in [true, false] {
      let a = Terminal(1), b = Terminal(0), source = Host(a), target = Host(b)
      source.transferIsBlocked = blockedSource; target.transferIsBlocked = !blockedSource
      XCTAssertThrowsError(try WorktreeTerminalTransfer.perform(from: source, to: target,
          replacement: Terminal(0)))
      XCTAssertTrue(source.terminalForTransfer === a); XCTAssertTrue(target.terminalForTransfer === b)
      XCTAssertEqual(source.replacements + target.replacements, 0)
    }
  }
  @MainActor func testSameHostTransferIsRejectedWithoutMutation() {
    let host = Host(Terminal(1))
    XCTAssertThrowsError(try WorktreeTerminalTransfer.perform(from: host, to: host,
        replacement: Terminal(0)))
    XCTAssertEqual(host.replacements, 0)
  }
}
