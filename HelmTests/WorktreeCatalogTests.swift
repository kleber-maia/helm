import XCTest

final class WorktreeCatalogTests: XCTestCase
{
  private let common = "/projects/repo/.git"
  private let sha = String(repeating: "a", count: 40)
  private func parse(_ text: String, metadata: [String: String] = [:],
                     exists: @escaping (String) -> Bool = { _ in true }) throws -> WorktreeInventory {
    try GitWorktreeCatalog.parse(Data(text.utf8), repositoryID: common,
                                privateDirectories: metadata, exists: exists)
  }
  func testPrimaryTrunkAndLinkedMainHaveCorrectStableRoles() throws {
    let text = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0" +
      "worktree /trees/main\0HEAD \(sha)\0branch refs/heads/main\0\0"
    let inventory = try parse(text, metadata: ["/trees/main": common + "/worktrees/linked"])
    XCTAssertTrue(inventory.records[0].isPrimary); XCTAssertEqual(inventory.records[0].branch, "trunk")
    XCTAssertFalse(inventory.records[1].isPrimary); XCTAssertEqual(inventory.records[1].branch, "main")
    XCTAssertEqual(inventory.records[1].id, common + "/worktrees/linked")
  }
  func testBranchMembershipIncludesLockedUnavailableRegistrationsAndSkipsDetached() throws {
    let text = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0" +
      "worktree /trees/offline\0HEAD \(sha)\0branch refs/heads/feature/owned\0locked offline\0prunable missing\0\0" +
      "worktree /trees/detached\0HEAD \(sha)\0detached\0\0"
    let inventory = try parse(text, metadata: ["/trees/offline": common + "/worktrees/offline",
        "/trees/detached": common + "/worktrees/detached"], exists: { $0 != "/trees/offline" })
    XCTAssertEqual(WorktreeBranchPolicy.linkedLocalRefs(in: inventory), ["refs/heads/feature/owned"])
  }

  func testRegisteredBranchMembershipTracksRenameCheckoutAndRemoval() throws {
    let primary = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0"
    let metadata = ["/trees/linked": common + "/worktrees/linked"]
    for name in ["feature/old", "feature/renamed", "other"] {
      let inventory = try parse(primary + "worktree /trees/linked\0HEAD \(sha)\0branch refs/heads/\(name)\0\0", metadata: metadata)
      XCTAssertEqual(WorktreeBranchPolicy.linkedLocalRefs(in: inventory), ["refs/heads/" + name])
    }
    XCTAssertTrue(WorktreeBranchPolicy.linkedLocalRefs(in: try parse(primary)).isEmpty)
  }

  func testGitMoveKeepsPrivateDirectoryIdentity() throws {
    let prefix = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0"
    let before = try parse(prefix + "worktree /trees/old\0HEAD \(sha)\0detached\0\0",
        metadata: ["/trees/old": common + "/worktrees/stable"])
    let after = try parse(prefix + "worktree /trees/new\0HEAD \(sha)\0detached\0\0",
        metadata: ["/trees/new": common + "/worktrees/stable"])
    XCTAssertEqual(before.records[1].id, after.records[1].id)
    XCTAssertNotEqual(before.records[1].path, after.records[1].path)
    XCTAssertEqual(after.records[1].title, "new/HEAD@aaaaaaa")
  }
  func testLockedPrunableMissingPathIsUnavailableNotOmitted() throws {
    let text = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0" +
      "worktree /trees/offline\0HEAD \(sha)\0locked removable drive\0prunable missing path\0\0"
    let inventory = try parse(text, metadata: ["/trees/offline": common + "/worktrees/offline"],
                              exists: { $0 != "/trees/offline" })
    XCTAssertEqual(inventory.records.count, 2)
    XCTAssertTrue(inventory.records[1].isLocked)
    XCTAssertEqual(inventory.records[1].availability, .unavailable)
  }
  func testNULFormatPreservesWhitespaceAndNewlinesInPath() throws {
    let path = "/trees/a b\nc"
    let text = "worktree \(path)\0HEAD \(sha)\0branch refs/heads/trunk\0\0"
    XCTAssertEqual(try parse(text).records[0].path, path)
  }
  func testIncompleteOrUnknownMetadataFailsWholeInventorySafely() {
    XCTAssertThrowsError(try parse("worktree /trees/root\0\0"))
    XCTAssertThrowsError(try parse("worktree /trees/root\0HEAD \(sha)\0\0worktree /trees/unknown\0HEAD \(sha)\0\0"))
    XCTAssertThrowsError(try parse(""))
  }
  func testUnavailablePrimaryRemainsPrimaryRegardlessOfBranch() throws {
    let inventory = try parse("worktree /trees/root\0HEAD \(sha)\0branch refs/heads/other\0\0", exists: { _ in false })
    XCTAssertTrue(inventory.primary!.isPrimary)
    XCTAssertEqual(inventory.primary!.availability, .unavailable)
  }
  func testPrivateMetadataNameReuseHasNewIdentity() throws {
    let raw = Data(("worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0" +
      "worktree /trees/linked\0HEAD \(sha)\0branch refs/heads/main\0\0").utf8)
    let metadata = ["/trees/linked": common + "/worktrees/linked"]
    let old = try GitWorktreeCatalog.parse(raw, repositoryID: common,
        privateDirectories: metadata, privateIdentities: ["/trees/linked": "incarnation-old"], exists: { _ in true })
    let fresh = try GitWorktreeCatalog.parse(raw, repositoryID: common,
        privateDirectories: metadata, privateIdentities: ["/trees/linked": "incarnation-new"], exists: { _ in true })
    XCTAssertNotEqual(old.records[1].id, fresh.records[1].id)
    XCTAssertEqual(old.records[1].privateDirectory, fresh.records[1].privateDirectory)
  }
  func testRecreatedWorktreeNeverReusesRetainedOldLiveSession() {
    let path = common + "/worktrees/linked"
    let old = WorktreeRecord(id: "old", repositoryID: common, path: "/trees/linked",
        branch: "main", head: sha, isPrimary: false, availability: .available, metadataPath: path)
    var fresh = old; fresh.id = "new"
    var tab = WorktreeTabState(sessionID: UUID(), binding: .init(record: old), terminalRunning: true)
    let inventory = WorktreeInventory(repositoryID: common, records: [fresh])
    XCTAssertNil(WorktreePolicy.preferred(fresh.id, in: [tab]))
    XCTAssertEqual(WorktreePolicy.removal(of: tab, inventory: inventory,
        metadataExists: true, pathExists: true), .removedWithWork)
    tab.terminalRunning = false
    XCTAssertEqual(WorktreePolicy.removal(of: tab, inventory: inventory,
        metadataExists: true, pathExists: true), .close)
  }

  func testPrunableEntryIsUnavailableEvenWhenItsOldFolderWasRecreated() throws {
    let text = "worktree /trees/root\0HEAD \(sha)\0branch refs/heads/trunk\0\0" +
      "worktree /trees/old\0HEAD \(sha)\0prunable gitdir file points elsewhere\0\0"
    let inventory = try parse(text, metadata: ["/trees/old": common + "/worktrees/old"],
                               exists: { _ in true })
    XCTAssertEqual(inventory.records[1].availability, .unavailable)
  }

}
