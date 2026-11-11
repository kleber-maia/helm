import Foundation
import CryptoKit
import Darwin

struct ActionsSnapshot
{
  let actions: [CustomAction]
  let revision: String
  let pendingConflicts: Int
  let location: URL
}

struct ActionsRecovery
{
  struct Choice: Identifiable {
    let id: String
    let label: String
    let actions: [CustomAction]
    fileprivate let conflictID: UUID
  }
  let revision: String
  let choices: [Choice]
  let backups: URL
}

struct ActionsStorageFailure: LocalizedError
{
  let message: String
  var errorDescription: String? { message }
}

/// File and journal share one atomic commit. Legacy preferences are read-only.
final class ActionsPersistence
{
  struct Configuration {
    let root: URL
    let fixtureFiles: [URL]?
    static let domains = ["group.soft.HelmIDE",
      "group.soft.HelmIDE.SidebarReview20261110",
      "group.soft.HelmIDE.WorktreeCandidate20261109",
      "group.soft.HelmIDE.WorktreeCandidateCWD20261109",
      "group.soft.HelmIDE.FixedWorktrees20261109",
      "group.soft.HelmIDE.SidebarReviewV220261110",
      "group.soft.HelmIDE.SidebarReviewV320261110"]

    static func current() throws -> Self {
#if HELM_ACTIONS_REVIEW_FIXTURE
      guard let root = Bundle.main.object(forInfoDictionaryKey: "HelmActionsFixtureRoot") as? String,
            let files = Bundle.main.object(forInfoDictionaryKey: "HelmActionsFixtureSources") as? [String],
            root.hasPrefix("/"), !files.isEmpty, files.allSatisfy({ $0.hasPrefix("/") }) else {
        throw ActionsStorageFailure(message: "Actions fixture configuration is missing. Normal Actions storage was not accessed.")
      }
      return .init(root: URL(fileURLWithPath: root),
                   fixtureFiles: files.map { URL(fileURLWithPath: $0) })
#else
      let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
      return .init(root: support.appendingPathComponent("Helm/Actions", isDirectory: true),
                   fixtureFiles: nil)
#endif
    }
  }

  struct Source {
    let domain: String
    let key: String
    let channel: String
    let raw: Data
    let encoding: String
    var id: String { ActionsPersistence.digest(Data((domain + "|" + key + "|" + channel).utf8)) }
    var fingerprint: String { ActionsPersistence.digest(raw) + ":" + encoding }
    var path: String { String(key.dropFirst("customActions-".count)) }
    var label: String { domain + " — " + (encoding == "store" ? key : path) }
  }
  private struct Conflict: Codable {
    var id = UUID()
    var label: String
    var actions: [CustomAction]
    var pending: Bool
  }
  private struct Document: Codable {
    var schemaVersion = 1
    var commonDirectory: String
    var aliases: [String]
    var actions: [CustomAction] = []
    var imports: [String: String] = [:]
    var conflicts: [Conflict] = []
  }
  private struct Context {
    let common: String
    let aliases: [String]
    let target: URL
  }
  private let configuration: Configuration
  init(configuration: Configuration) { self.configuration = configuration }
  private var files: URL { configuration.root.appendingPathComponent("v1", isDirectory: true) }
  private var backups: URL { configuration.root.appendingPathComponent("Backups", isDirectory: true) }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func fail(_ message: String) -> ActionsStorageFailure { .init(message: message) }
  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(value)
  }
  private func revision(_ raw: Data?) -> String { raw.map(Self.digest) ?? "absent" }

  private func context(_ path: String) throws -> Context {
    let inventory = try GitWorktreeCatalog.discover(at: URL(fileURLWithPath: path))
    let common = inventory.repositoryID
    return .init(common: common,
        aliases: Array(Set(inventory.records.map(\.path) + [GitWorktreeCatalog.canonical(path)])).sorted(),
        target: files.appendingPathComponent(Self.digest(Data(common.utf8)) + ".json"))
  }

  private func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    guard a[.type] as? FileAttributeType == .typeDirectory,
          (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
          ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
      throw fail("The Actions storage directory is not private or is a symbolic link. No Actions were changed: \(url.path)")
    }
  }

  private func locked<T>(_ path: String, _ body: (Context) throws -> T) throws -> T {
    let c = try context(path)
    try privateDirectory(configuration.root)
    try privateDirectory(files)
    try privateDirectory(backups)
    let fd = open(configuration.root.appendingPathComponent(".lock").path,
                  O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw fail("The Actions storage lock could not be opened. No Actions were changed.") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw fail("Another Helm build is saving or migrating Actions. Wait and retry; your edits remain open.")
    }
    defer { flock(fd, LOCK_UN) }
    return try body(c)
  }

  private func readTarget(_ target: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
    let a = try FileManager.default.attributesOfItem(atPath: target.path)
    guard a[.type] as? FileAttributeType == .typeRegular else {
      throw fail("The Actions file is not a regular file. It was not replaced.")
    }
    return try Data(contentsOf: target)
  }
  private func decode(_ raw: Data?) throws -> Document? {
    guard let raw else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let version = object["schemaVersion"] as? Int else {
      throw fail("The saved Actions file is unreadable. Do not save an empty replacement; use Recover Saved Actions.")
    }
    guard version == 1 else {
      throw fail("This Actions file uses an unsupported/newer version. Use a compatible Helm build; it was not replaced.")
    }
    do { return try JSONDecoder().decode(Document.self, from: raw) }
    catch { throw fail("The saved Actions file is incomplete or unreadable. Use Recover Saved Actions; it was not replaced.") }
  }
  private func actionArray(_ source: Source) throws -> [CustomAction] {
    do {
      let actions: [CustomAction]
      if source.encoding == "store" { actions = try decode(source.raw)!.actions }
      else {
        guard source.encoding == "json" else { throw fail("Unsupported legacy value") }
        actions = try JSONDecoder().decode([CustomAction].self, from: source.raw)
      }
      guard Set(actions.map(\.id)).count == actions.count else { throw fail("Duplicate action identifiers") }
      return actions
    }
    catch { throw fail("A saved Actions source could not be decoded safely (\(source.domain)). Its raw bytes and original preference key are retained; no empty replacement was saved.") }
  }

  /// Only known Action keys are captured, never account/other preference keys.
  private func legacySources() throws -> [Source] {
    var result: [Source] = []
    func collect(_ values: [String: Any], domain: String, channel: String) throws {
      for key in values.keys.sorted() where key.hasPrefix("customActions-") {
        let value = values[key]!
        let data: Data
        let encoding: String
        if let raw = value as? Data { data = raw; encoding = "json" }
        else {
          data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
          encoding = "unsupported-property-list"
        }
        result.append(.init(domain: domain, key: key, channel: channel, raw: data, encoding: encoding))
      }
    }
    if let fixtures = configuration.fixtureFiles {
      for file in fixtures {
        guard let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any],
              let domain = root["domain"] as? String, let values = root["values"] as? [String: Any] else {
          throw fail("The isolated legacy Actions fixture is unreadable. Normal preferences were not accessed.")
        }
        try collect(values, domain: domain, channel: file.path)
      }
    }
    else {
      var domains = Configuration.domains
      if let own = Bundle.main.bundleIdentifier, !domains.contains(own) { domains.append(own) }
      for domain in domains {
        let file = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Preferences/\(domain).plist")
        if FileManager.default.fileExists(atPath: file.path) {
          guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
            throw fail("Legacy preferences are unreadable (\(domain)). Original data was not modified; migration stopped.")
          }
          try collect(values, domain: domain, channel: "disk")
        }
        // Preserve potentially newer cached values too; do not synchronize/write.
        if let values = UserDefaults.standard.persistentDomain(forName: domain) {
          try collect(values, domain: domain, channel: "preferences")
        }
      }
    }
    return result
  }

  private func belongs(_ source: Source, to c: Context, aliases: [String]) -> Bool {
    let path = GitWorktreeCatalog.canonical(source.path)
    if Set(c.aliases + aliases).contains(path) { return true }
    guard FileManager.default.fileExists(atPath: path),
          let inventory = try? GitWorktreeCatalog.discover(at: URL(fileURLWithPath: path)) else { return false }
    return inventory.repositoryID == c.common
  }
  private func sourceState(_ sources: [Source]) -> String {
    Self.digest(Data(sources.map { $0.id + ":" + $0.fingerprint }.sorted().joined(separator: "\n").utf8))
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw fail("A private Actions backup/temp file could not be created. No original was replaced.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard try Data(contentsOf: url) == data else { throw fail("Actions backup verification failed. Originals were not replaced.") }
  }

  /// Content-addressed backup reuses only a byte-verified complete snapshot.
  private func backup(_ raw: Data?, sources: [Source]) throws -> URL {
    let signature = revision(raw) + sourceState(sources)
    let name = Self.digest(Data(signature.utf8))
    var directory = backups.appendingPathComponent(name, isDirectory: true)
    func valid(_ directory: URL) -> Bool {
      guard let manifest = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            object["snapshot"] as? String == name else { return false }
      if let raw, (try? Data(contentsOf: directory.appendingPathComponent("previous-store.json"))) != raw { return false }
      for (index, source) in sources.enumerated() {
        if (try? Data(contentsOf: directory.appendingPathComponent("legacy-\(index).bin"))) != source.raw { return false }
      }
      return true
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try privateDirectory(directory)
      if valid(directory) { return directory }
      // Never overwrite a partial/corrupt backup from an interrupted run.
      directory = backups.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
    }
    try privateDirectory(directory)
    if let raw { try writePrivate(raw, to: directory.appendingPathComponent("previous-store.json")) }
    var entries: [[String: String]] = []
    for (index, source) in sources.enumerated() {
      let file = "legacy-\(index).bin"
      try writePrivate(source.raw, to: directory.appendingPathComponent(file))
      entries.append(["file": file, "domain": source.domain, "key": source.key,
                      "channel": source.channel, "encoding": source.encoding,
                      "sha256": Self.digest(source.raw)])
    }
    let manifest: [String: Any] = ["snapshot": name, "created": ISO8601DateFormatter().string(from: Date()),
      "previousStoreSHA256": raw.map(Self.digest) ?? "absent", "sources": entries]
    try writePrivate(try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]),
                     to: directory.appendingPathComponent("manifest.json"))
    guard valid(directory) else { throw fail("Actions backup is incomplete. Nothing was migrated or replaced.") }
    return directory
  }

  private func prepared(_ raw: Data?, sources: [Source], context c: Context) throws -> (Document, Bool) {
    let old: Document?
    do { old = try decode(raw) }
    catch {
      let saved = try backup(raw, sources: sources)
      throw fail(error.localizedDescription + " Verified private backup: " + saved.path)
    }
    var document = old ?? Document(commonDirectory: c.common, aliases: c.aliases)
    var changed = false
    for source in sources {
      if document.imports[source.id] == source.fingerprint { continue }
      let incoming: [CustomAction]
      do { incoming = try actionArray(source) }
      catch {
        let saved = try backup(raw, sources: sources)
        throw fail(error.localizedDescription + " Verified private backup: " + saved.path)
      }
      if !incoming.isEmpty && incoming != document.actions {
        let disjoint = Set(incoming.map(\.id)).isDisjoint(with: document.actions.map(\.id))
        let ids = Set(incoming.map(\.id))
        let alreadyPresentInOrder = document.actions.filter { ids.contains($0.id) } == incoming
        if alreadyPresentInOrder { /* Same definitions already imported from another legacy copy. */ }
        else if document.actions.isEmpty || disjoint { document.actions.append(contentsOf: incoming) }
        else if !document.conflicts.contains(where: { $0.actions == incoming }) {
          document.conflicts.append(.init(label: source.label, actions: incoming, pending: true))
        }
      }
      document.imports[source.id] = source.fingerprint
      changed = true
    }
    let aliases = Array(Set(document.aliases + c.aliases)).sorted()
    if aliases != document.aliases { document.aliases = aliases; changed = true }
    return (document, changed)
  }

  private func commit(_ document: Document, old: Data?, sources: [Source], context c: Context,
                      revalidate: () throws -> Bool) throws -> Data {
    let verified = try backup(old, sources: sources)
    guard try readTarget(c.target) == old, try revalidate() else {
      throw fail("Actions changed in another window/build during migration. No original was replaced. Retry; backup: \(verified.path)")
    }
    let data = try encoded(document)
    let temporary = files.appendingPathComponent(".\(UUID().uuidString).tmp")
    try writePrivate(data, to: temporary)
    guard rename(temporary.path, c.target.path) == 0 else {
      throw fail("Actions could not be atomically saved. Previous data and verified backup remain; retry after checking storage permissions.")
    }
    guard try Data(contentsOf: c.target) == data else {
      throw fail("The last Actions save could not be verified. Do not overwrite it; reopen/recover from verified backup: \(verified.path)")
    }
    return data
  }
  private func snapshot(_ d: Document, raw: Data?, c: Context) -> ActionsSnapshot {
    .init(actions: d.actions, revision: revision(raw), pendingConflicts: d.conflicts.filter(\.pending).count, location: c.target)
  }

  func load(_ path: String) throws -> ActionsSnapshot {
    try locked(path) { c in
      let raw = try readTarget(c.target)
      let aliases = (try? decode(raw))?.aliases ?? []
      let sources = try legacySources().filter { belongs($0, to: c, aliases: aliases) }
      let (document, changed) = try prepared(raw, sources: sources, context: c)
      let final = changed ? try commit(document, old: raw, sources: sources, context: c, revalidate: {
        sourceState(try legacySources().filter { belongs($0, to: c, aliases: aliases) }) == sourceState(sources)
      }) : raw
      return snapshot(document, raw: final, c: c)
    }
  }

  func save(_ actions: [CustomAction], at path: String, expected: String) throws -> ActionsSnapshot {
    try locked(path) { c in
      let raw = try readTarget(c.target)
      guard revision(raw) == expected else { throw fail("Actions changed in another window/build. Your editor remains open with all edits; cancel/reopen to load the newer version.") }
      guard Set(actions.map(\.id)).count == actions.count else { throw fail("Actions have duplicate identifiers. Nothing was saved; keep the editor open and resolve the duplicate.") }
      let aliases = (try? decode(raw))?.aliases ?? []
      let sources = try legacySources().filter { belongs($0, to: c, aliases: aliases) }
      var (document, changed) = try prepared(raw, sources: sources, context: c)
      // The editor's revision covers the file, but old builds still write
      // legacy preferences. Never mark fresh imports consumed and then replace
      // them with a stale editor snapshot.
      guard !changed else {
        throw fail("Older saved Actions changed while this editor was open. Your edits remain open; cancel/reopen to import the newer definitions before saving.")
      }
      if document.actions != actions {
        document.actions = actions; changed = true
      }
      let final = changed || raw == nil ? try commit(document, old: raw, sources: sources, context: c, revalidate: {
        sourceState(try legacySources().filter { belongs($0, to: c, aliases: aliases) }) == sourceState(sources)
      }) : raw
      return snapshot(document, raw: final, c: c)
    }
  }

  func recovery(_ path: String) throws -> ActionsRecovery {
    try locked(path) { c in
      let raw = try readTarget(c.target)
      let document = try decode(raw)
      let choices = (document?.conflicts ?? []).filter(\.pending).map {
        ActionsRecovery.Choice(id: $0.id.uuidString, label: $0.label,
                               actions: $0.actions, conflictID: $0.id)
      }
      return .init(revision: revision(raw), choices: choices, backups: backups)
    }
  }

  func recover(_ choice: ActionsRecovery.Choice, at path: String,
               expected: String, keepCurrent: Bool) throws -> ActionsSnapshot {
    try locked(path) { c in
      let raw = try readTarget(c.target)
      guard revision(raw) == expected, var document = try decode(raw),
            let index = document.conflicts.firstIndex(where: {
              $0.id == choice.conflictID && $0.actions == choice.actions && $0.pending
            }) else {
        throw fail("Actions changed after this conflict was opened. Reopen it; nothing was replaced.")
      }
      let sources = try legacySources().filter { belongs($0, to: c, aliases: document.aliases) }
      if !keepCurrent { document.actions = choice.actions }
      // Retain BOTH sets in the verified pre-write backup and source keys;
      // retain the incoming set here too, without changing its original IDs.
      document.conflicts[index].pending = false
      let final = try commit(document, old: raw, sources: sources, context: c, revalidate: {
        sourceState(try legacySources().filter { belongs($0, to: c, aliases: document.aliases) }) == sourceState(sources)
      })
      return snapshot(document, raw: final, c: c)
    }
  }
}
