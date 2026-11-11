import Foundation
import CryptoKit
import Darwin

/// Tab identity belongs to a session, never to its repository path.
struct RepositorySession: Codable, Equatable
{
  struct Tab: Codable, Equatable
  {
    var id: UUID
    var path: String
    var terminalDirectory: String? = nil
    var binding: WorktreeBinding? = nil

    func restoredRecord(in inventory: WorktreeInventory,
                        legacyLookup: (String) -> WorktreeRecord?) -> WorktreeRecord?
    {
      if let binding {
        guard binding.record.repositoryID == inventory.repositoryID else { return nil }
        return inventory.records.first { $0.id == binding.record.id }
      }
      return legacyLookup(path)
    }
  }

  struct Window: Codable, Equatable
  {
    struct Presentation: Codable, Equatable {
      enum Mode: String, Codable { case normal, zoomed, fullScreen }
      var normalFrame: String
      var windowedFrame: String? = nil
      var mode: Mode = .normal
      var windowedMode: Mode? = nil
      var sidebarWidth: Double? = nil
      var sidebarPolicyVersion: Int? = nil
      var sidebarHidden: Bool? = nil

      func restoredSidebarWidth(resolved: Double) -> Double {
        let width = sidebarWidth ?? resolved
        return sidebarPolicyVersion == nil && abs(width - 180) <= 1 ? 240 : width
      }
    }
    var tabs: [Tab]
    var selectedTabID: UUID?
    var presentation: Presentation? = nil
  }

  var version = 3
  var windows: [Window]
  var activeTabID: UUID?

  var isEmpty: Bool { windows.allSatisfy { $0.tabs.isEmpty } }

  /// Keep unavailable entries through partial restores and repeated Quit cycles.
  /// They are neither silently forgotten nor treated as confirmed removals.
  func retaining(_ saved: RepositorySession, ids: Set<UUID>) -> RepositorySession
  {
    var result = self
    var present = Set(windows.flatMap(\.tabs).map(\.id))
    for oldWindow in saved.windows {
      let missing = oldWindow.tabs.filter { ids.contains($0.id) && !present.contains($0.id) }
      guard !missing.isEmpty else { continue }
      let repoIDs = Set(oldWindow.tabs.compactMap { $0.binding?.record.repositoryID })
      let index = result.windows.firstIndex { current in
        current.tabs.contains { tab in
          tab.binding.map { repoIDs.contains($0.record.repositoryID) } ?? false
        }
      }
      if let index {
        for tab in missing {
          let oldIndex = oldWindow.tabs.firstIndex { $0.id == tab.id }!
          let nextIDs = Set(oldWindow.tabs.dropFirst(oldIndex + 1).map(\.id))
          let insertion = result.windows[index].tabs.firstIndex { nextIDs.contains($0.id) }
                         ?? result.windows[index].tabs.endIndex
          result.windows[index].tabs.insert(tab, at: insertion)
          present.insert(tab.id)
        }
      }
      else {
        result.windows.append(.init(tabs: missing,
            selectedTabID: missing.contains { $0.id == oldWindow.selectedTabID }
                ? oldWindow.selectedTabID : missing.first?.id,
            presentation: oldWindow.presentation))
        missing.forEach { present.insert($0.id) }
      }
    }
    if result.activeTabID == nil, let active = saved.activeTabID, present.contains(active) {
      result.activeTabID = active
    }
    return result
  }

  func recoverableTab(for record: WorktreeRecord, ids: Set<UUID>) -> Tab?
  {
    windows.flatMap(\.tabs).first { tab in
      guard ids.contains(tab.id) else { return false }
      if let binding = tab.binding { return binding.record.id == record.id }
      let old = URL(fileURLWithPath: tab.path).standardizedFileURL.resolvingSymlinksInPath()
      let current = URL(fileURLWithPath: record.path).standardizedFileURL.resolvingSymlinksInPath()
      return old == current
    }
  }

  static func localTerminalDirectory(_ value: String?) -> URL?
  {
    guard let value, let url = URL(string: value),
          url.isFileURL, url.path.hasPrefix("/"),
          url.query == nil, url.fragment == nil
    else { return nil }
    let host = url.host?.lowercased() ?? ""
    let localHosts = ["", "localhost", "127.0.0.1", "::1",
                      ProcessInfo.processInfo.hostName.lowercased()]
    guard localHosts.contains(host) else { return nil }
    return validDirectory(url.path)
  }

  static func validDirectory(_ path: String?) -> URL?
  {
    guard let path, path.hasPrefix("/") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path,
                                         isDirectory: &isDirectory),
          isDirectory.boolValue else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

/// QA can use an explicit isolated suite; delivered builds never contain these
/// fixture keys/condition. Actions storage is not redirected or seeded.
enum WindowPersistence
{
  static var isFixture: Bool {
#if HELM_WINDOW_STATE_REVIEW_FIXTURE
    true
#else
    false
#endif
  }
  static var suite: String {
#if HELM_WINDOW_STATE_REVIEW_FIXTURE
    guard let value = Bundle.main.object(forInfoDictionaryKey: "HelmWindowFixtureSuite") as? String,
          value.hasPrefix("helm.window.fixture.") else { preconditionFailure("Missing isolated window suite") }
    return value
#else
    return Bundle.main.bundleIdentifier ?? "group.soft.HelmIDE"
#endif
  }
  static var defaults: UserDefaults {
    isFixture ? UserDefaults(suiteName: suite)! : .standard
  }
  static var backupRoot: URL {
#if HELM_WINDOW_STATE_REVIEW_FIXTURE
    guard let value = Bundle.main.object(forInfoDictionaryKey: "HelmWindowFixtureBackupRoot") as? String,
          value.hasPrefix("/") else { preconditionFailure("Missing isolated backup root") }
    return URL(fileURLWithPath: value)
#else
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Helm/WindowStateBackups", isDirectory: true)
#endif
  }
}

final class RepositorySessionStore
{
  static let key = "repositorySessions.v1"
  private let defaults: UserDefaults
  private(set) var failure: String?
  private var blocked = false
  private let backupRoot: URL

  init(defaults: UserDefaults? = nil, backupRoot: URL? = nil) {
    self.defaults = defaults ?? WindowPersistence.defaults
    self.backupRoot = backupRoot ?? WindowPersistence.backupRoot
  }

  func load() -> RepositorySession?
  {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    guard let session = try? JSONDecoder().decode(RepositorySession.self, from: data),
          (1...3).contains(session.version) else {
      blocked = true
      failure = "Saved tabs use an unreadable/newer format. Original data is retained; session saving is blocked rather than replacing it with an empty layout."
      return nil
    }
    return session
  }

  private func verifiedBackup(_ data: Data?) throws
  {
    var values: [String: Any] = [:]
    if let data { values[Self.key] = data }
    if let frame = defaults.string(forKey: "NSWindow Frame HelmDocument") {
      values["NSWindow Frame HelmDocument"] = frame
    }
    let raw = try PropertyListSerialization.data(fromPropertyList:
        ["domain": WindowPersistence.suite, "values": values], format: .binary, options: 0)
    let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    let root = backupRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let a = try FileManager.default.attributesOfItem(atPath: root.path)
    guard a[.type] as? FileAttributeType == .typeDirectory,
          (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
          ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
      throw NSError(domain: "HelmWindowBackup", code: 1)
    }
    let target = root.appendingPathComponent(hash + ".plist")
    if !FileManager.default.fileExists(atPath: target.path) {
      let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
      guard fd >= 0 else { throw NSError(domain: "HelmWindowBackup", code: 2) }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try file.write(contentsOf: raw); try file.synchronize(); try file.close()
    }
    guard try Data(contentsOf: target) == raw else { throw NSError(domain: "HelmWindowBackup", code: 3) }
  }

  @discardableResult
  func save(_ session: RepositorySession) -> Bool
  {
    guard !blocked, !session.isEmpty else { return false }
    do {
      let data = try JSONEncoder().encode(session)
      let old = defaults.data(forKey: Self.key)
      if old == data { return true }
      if let old {
        guard let previous = try? JSONDecoder().decode(RepositorySession.self, from: old),
              (1...3).contains(previous.version) else {
          blocked = true
          throw NSError(domain: "HelmWindowBackup", code: 4)
        }
      }
      try verifiedBackup(old)
      guard defaults.data(forKey: Self.key) == old else { throw NSError(domain: "HelmWindowBackup", code: 5) }
      defaults.set(data, forKey: Self.key)
      failure = nil
      return true
    }
    catch {
      failure = "Window/session state was not replaced because its private backup or source revalidation failed. Original data is retained. Backups: " + backupRoot.path
      return false
    }
  }
}
