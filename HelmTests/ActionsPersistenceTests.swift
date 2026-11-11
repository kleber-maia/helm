import XCTest
import Darwin

final class ActionsPersistenceTests: XCTestCase
{
  private var root: URL!
  private var repo: URL!
  private var legacy: URL!
  private var store: ActionsPersistence!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-actions-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    repo = root.appendingPathComponent("repo")
    legacy = root.appendingPathComponent("legacy.plist")
    try git(["init", "-b", "trunk", repo.path])
    try git(["-C", repo.path, "config", "core.hooksPath", "/dev/null"])
    try git(["-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Actions fixture"])
    try source([])
    store = ActionsPersistence(configuration: .init(root: root.appendingPathComponent("Store"), fixtureFiles: [legacy]))
  }
  override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
  private func git(_ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
    var env = ProcessInfo.processInfo.environment; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"; process.environment = env
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run(); process.waitUntilExit()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else { throw NSError(domain: "FixtureGit", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)]) }
  }
  private func action(_ name: String) -> CustomAction {
    var value = CustomAction(name: name, commands: "fixture text — never executed")
    value.extraFields["future"] = .object(["enabled": .bool(true), "integer": .unsigned(UInt64.max), "values": .array([.null, .string("fixture")])])
    return value
  }
  private func source(_ actions: [CustomAction], path: String? = nil) throws {
    let raw = try JSONEncoder().encode(actions)
    let data = try PropertyListSerialization.data(fromPropertyList: ["domain": "HelmTests.fixture", "values": ["customActions-" + (path ?? repo.path): raw]], format: .binary, options: 0)
    try data.write(to: legacy, options: .atomic)
  }
  func testMigrationSharesPrimaryLinkedAndPreservesIDsOrderUnknownFieldsAndSource() throws {
    let values = [action("one"), action("two")]; try source(values)
    let original = try Data(contentsOf: legacy)
    let linked = root.appendingPathComponent("linked")
    try git(["-C", repo.path, "worktree", "add", "-b", "linked", linked.path])
    let primary = try store.load(repo.path), other = try store.load(linked.path)
    XCTAssertEqual(primary.actions, values); XCTAssertEqual(other.actions, values)
    XCTAssertEqual(primary.location, other.location)
    XCTAssertEqual(try Data(contentsOf: legacy), original)
    XCTAssertEqual(try store.load(repo.path).actions, values)
    let backups = root.appendingPathComponent("Store/Backups")
    let directories = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    XCTAssertFalse(directories.isEmpty)
    let captured = try XCTUnwrap(try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
    let sources = try XCTUnwrap(captured["values"] as? [String: Data])
    let raw = try XCTUnwrap(sources["customActions-" + repo.path])
    XCTAssertTrue(directories.contains { (try? Data(contentsOf: $0.appendingPathComponent("legacy-0.bin"))) == raw })
  }
  func testEditingReorderKeepsOriginalIDsAndExtraConfiguration() throws {
    let values = [action("one"), action("two")]; try source(values)
    let current = try store.load(repo.path)
    var edited = Array(current.actions.reversed()); edited[0].name = "renamed"
    _ = try store.save(edited, at: repo.path, expected: current.revision)
    XCTAssertEqual(try store.load(repo.path).actions, edited)
    XCTAssertEqual(edited[0].extraFields, values[1].extraFields)
  }
  func testLegacyArrivalDuringEditorCannotBeConsumedAndDropped() throws {
    let first = action("one"), incoming = action("new legacy")
    try source([first]); let opened = try store.load(repo.path)
    let originalTarget = try Data(contentsOf: opened.location)
    try source([incoming])
    var edited = first; edited.name = "unsaved edit"
    XCTAssertThrowsError(try store.save([edited], at: repo.path, expected: opened.revision))
    XCTAssertEqual(try Data(contentsOf: opened.location), originalTarget)
    let refreshed = try store.load(repo.path)
    XCTAssertEqual(refreshed.actions, [first, incoming])
    XCTAssertEqual(try store.load(repo.path).actions, refreshed.actions)
  }
  func testConcurrentNewStoreRevisionRejectsStaleEditor() throws {
    let first = action("one"); try source([first]); let opened = try store.load(repo.path)
    var newer = first; newer.name = "newer"
    _ = try store.save([newer], at: repo.path, expected: opened.revision)
    XCTAssertThrowsError(try store.save([first], at: repo.path, expected: opened.revision))
    XCTAssertEqual(try store.load(repo.path).actions, [newer])
  }
  func testConflictingLegacyKeepsCurrentUntilExplicitReplacement() throws {
    let original = action("original"); try source([original]); _ = try store.load(repo.path)
    var incoming = original; incoming.name = "older different version"
    try source([incoming]); let conflict = try store.load(repo.path)
    XCTAssertEqual(conflict.actions, [original]); XCTAssertEqual(conflict.pendingConflicts, 1)
    let recovery = try store.recovery(repo.path)
    let choice = try XCTUnwrap(recovery.choices.first)
    _ = try store.recover(choice, at: repo.path, expected: recovery.revision, keepCurrent: false)
    XCTAssertEqual(try store.load(repo.path).actions, [incoming])
    XCTAssertEqual(try store.load(repo.path).pendingConflicts, 0)
  }
  func testKeepCurrentArchivesConflictWithoutChangingIDs() throws {
    let original = action("original"); try source([original]); _ = try store.load(repo.path)
    var incoming = original; incoming.name = "different"
    try source([incoming]); _ = try store.load(repo.path)
    let recovery = try store.recovery(repo.path)
    _ = try store.recover(XCTUnwrap(recovery.choices.first), at: repo.path, expected: recovery.revision, keepCurrent: true)
    let result = try store.load(repo.path)
    XCTAssertEqual(result.actions, [original]); XCTAssertEqual(result.pendingConflicts, 0)
    XCTAssertTrue(String(decoding: try Data(contentsOf: result.location), as: UTF8.self).contains("different"))
  }
  func testBackupFailureDoesNotProduceEmptyReplacement() throws {
    let values = [action("one")]; try source(values)
    let directory = root.appendingPathComponent("Store")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data("blocked".utf8).write(to: directory.appendingPathComponent("Backups"))
    let original = try Data(contentsOf: legacy)
    XCTAssertThrowsError(try store.load(repo.path))
    XCTAssertEqual(try Data(contentsOf: legacy), original)
    XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("v1").path)) ?? [], [])
  }
  func testMalformedSourceIsBackedUpAndNeverReplaced() throws {
    let broken = Data("invalid fixture JSON".utf8)
    try PropertyListSerialization.data(fromPropertyList: ["domain": "HelmTests.fixture", "values": ["customActions-" + repo.path: broken]], format: .binary, options: 0).write(to: legacy)
    XCTAssertThrowsError(try store.load(repo.path))
    let backups = root.appendingPathComponent("Store/Backups")
    let directories = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    XCTAssertTrue(directories.contains { (try? Data(contentsOf: $0.appendingPathComponent("legacy-0.bin"))) == broken })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Store/v1").path), [])
  }
  func testUnavailableLegacyPathIsRetainedRatherThanGuessed() throws {
    try source([action("unavailable")], path: root.appendingPathComponent("missing/repo").path)
    let raw = try Data(contentsOf: legacy)
    XCTAssertTrue(try store.load(repo.path).actions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: legacy), raw)
  }
  func testHeldStoreLockBlocksOtherWriter() throws {
    try source([action("one")]); let snapshot = try store.load(repo.path)
    let fd = open(root.appendingPathComponent("Store/.lock").path, O_RDWR)
    XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }
    defer { flock(fd, LOCK_UN); close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    XCTAssertThrowsError(try store.save(snapshot.actions, at: repo.path, expected: snapshot.revision))
  }
}
