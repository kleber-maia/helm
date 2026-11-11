import XCTest
import Darwin

final class TerminalProcessDirectoryTests: XCTestCase
{
  private struct Child {
    var process: Process
    var input: Pipe
    var output: Pipe
    func change(to path: String) throws {
      try input.fileHandleForWriting.write(contentsOf: Data((path + "\n").utf8))
      XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("C".utf8))
    }
    func finish() {
      input.fileHandleForWriting.closeFile()
      process.waitUntilExit()
    }
  }
  private func child(at directory: URL) throws -> Child {
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf R; while IFS= read -r path; do cd \"$path\" || exit 2; printf C; done"]
    process.currentDirectoryURL = directory
    process.standardInput = input; process.standardOutput = output
    try process.run()
    XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
    return .init(process: process, input: input, output: output)
  }
  private func read(_ child: Child, _ identity: HelmProcessIdentity)
      -> (Bool, HelmDirectoryIdentity) {
    var path = [CChar](repeating: 0, count: 4096), directory = HelmDirectoryIdentity()
    let success = HelmOwnedProcessDirectoryInfo(child.process.processIdentifier,
        identity, &path, path.count, &directory)
    return (success, directory)
  }
  func testOwnedChildCWDAndBirthIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = try child(at: first); defer { child.finish() }
    var identity = HelmProcessIdentity()
    XCTAssertTrue(HelmOwnedProcessIdentity(child.process.processIdentifier, &identity))
    let before = read(child, identity); XCTAssertTrue(before.0)
    try child.change(to: second.path)
    let after = read(child, identity); XCTAssertTrue(after.0)
    XCTAssertNotEqual(before.1.inode, after.1.inode)
    identity.seconds += 1
    XCTAssertFalse(read(child, identity).0)
  }
  func testRemovedRecreatedPathDoesNotMasqueradeAsOldCWD() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("held")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = try child(at: directory); defer { child.finish() }
    var identity = HelmProcessIdentity()
    XCTAssertTrue(HelmOwnedProcessIdentity(child.process.processIdentifier, &identity))
    let before = read(child, identity); XCTAssertTrue(before.0)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertFalse(read(child, identity).0)
    try child.change(to: directory.path)
    let after = read(child, identity); XCTAssertTrue(after.0)
    XCTAssertNotEqual(before.1.inode, after.1.inode)
  }
  func testForeignAndExitedProcessAreRejected() throws {
    var identity = HelmProcessIdentity()
    XCTAssertFalse(HelmOwnedProcessIdentity(getpid(), &identity))
    XCTAssertFalse(HelmOwnedProcessIdentity(0, &identity))
    let child = try child(at: FileManager.default.temporaryDirectory)
    XCTAssertTrue(HelmOwnedProcessIdentity(child.process.processIdentifier, &identity))
    child.finish()
    XCTAssertFalse(read(child, identity).0)
  }
}
