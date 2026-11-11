import Foundation

struct GitWorktreeCatalog
{
  enum Failure: LocalizedError {
    case command(String), invalidInventory
    var errorDescription: String? {
      switch self {
        case .command(let message): return message
        case .invalidInventory: return "Git returned incomplete or invalid worktree information."
      }
    }
  }

  static func canonical(_ path: String) -> String
  {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func discover(at url: URL) throws -> WorktreeInventory
  {
    let common = try command(["-C", url.path, "rev-parse",
                              "--path-format=absolute", "--git-common-dir"])
    guard let path = String(data: common, encoding: .utf8)?.trimmingCharacters(
        in: .newlines), !path.isEmpty else { throw Failure.invalidInventory }
    return try read(commonDirectory: canonical(path))
  }

  static func read(commonDirectory: String) throws -> WorktreeInventory
  {
    let common = canonical(commonDirectory)
    let data = try command(["--git-dir", common, "worktree", "list",
                            "--porcelain", "-z"])
    var privateDirectories: [String: String] = [:]
    var privateIdentities: [String: String] = [:]
    let metadata = URL(fileURLWithPath: common).appendingPathComponent("worktrees")
    for entry in (try? FileManager.default.contentsOfDirectory(
        at: metadata, includingPropertiesForKeys: nil)) ?? [] {
      guard let data = try? String(contentsOf: entry.appendingPathComponent("gitdir"),
                                   encoding: .utf8) else { continue }
      let gitFile = data.hasSuffix("\n") ? String(data.dropLast()) : data
      let path = URL(fileURLWithPath: gitFile).deletingLastPathComponent().path
      privateDirectories[canonical(path)] = canonical(entry.path)
      if let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
         let inode = attributes[.systemFileNumber] as? NSNumber,
         let device = attributes[.systemNumber] as? NSNumber,
         let created = attributes[.creationDate] as? Date {
        privateIdentities[canonical(path)] = canonical(entry.path) + "#" +
          device.stringValue + ":" + inode.stringValue + ":" +
          String(created.timeIntervalSince1970.bitPattern)
      }
    }
    return try parse(data, repositoryID: common,
                     privateDirectories: privateDirectories,
                     privateIdentities: privateIdentities,
                     exists: { path in
      var directory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
             && directory.boolValue
    })
  }

  static func parse(_ data: Data, repositoryID: String,
                    privateDirectories: [String: String],
                    privateIdentities: [String: String] = [:],
                    exists: (String) -> Bool) throws -> WorktreeInventory
  {
    guard let raw = String(data: data, encoding: .utf8) else {
      throw Failure.invalidInventory
    }
    var records: [WorktreeRecord] = []
    var fields: [String] = []
    func appendRecord() throws {
      guard !fields.isEmpty else { return }
      guard let pathField = fields.first, pathField.hasPrefix("worktree "),
            !fields.contains("bare") else { throw Failure.invalidInventory }
      let path = canonical(String(pathField.dropFirst(9)))
      let primary = records.isEmpty
      guard path.hasPrefix("/"),
            let metadata = primary ? repositoryID : privateDirectories[path]
      else { throw Failure.invalidInventory }
      let branch = fields.first { $0.hasPrefix("branch refs/heads/") }
        .map { String($0.dropFirst(18)) }
      let head = fields.first { $0.hasPrefix("HEAD ") }
        .map { String($0.dropFirst(5)) }
      guard let head, (head.count == 40 || head.count == 64),
            head.allSatisfy({ $0.isHexDigit }) else { throw Failure.invalidInventory }
      let id = primary ? repositoryID : (privateIdentities[path] ?? metadata)
      records.append(.init(id: id, repositoryID: repositoryID, path: path,
          branch: branch, head: head, isPrimary: primary,
          isLocked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
          availability: exists(path) && !fields.contains(where: {
            $0 == "prunable" || $0.hasPrefix("prunable ")
          }) ? .available : .unavailable,
          metadataPath: metadata))
    }
    for field in raw.components(separatedBy: "\0") {
      if field.isEmpty { try appendRecord(); fields.removeAll() }
      else { fields.append(field) }
    }
    try appendRecord()
    guard !records.isEmpty, Set(records.map(\.id)).count == records.count
    else { throw Failure.invalidInventory }
    return .init(repositoryID: repositoryID, records: records)
  }

  static func locate(_ directory: URL, in inventory: WorktreeInventory) -> WorktreeRecord?
  {
    guard let data = try? command(["-C", directory.path, "rev-parse", "--absolute-git-dir"]),
          let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    else { return nil }
    let privatePath = canonical(path)
    return inventory.records.first { $0.privateDirectory == privatePath }
  }

  private static func command(_ arguments: [String]) throws -> Data
  {
    let process = Process()
    let output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.command(String(data: errorData, encoding: .utf8) ?? "Git failed")
    }
    return data
  }
}
