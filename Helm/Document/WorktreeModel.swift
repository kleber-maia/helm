import Foundation

struct WorktreeRecord: Codable, Equatable, Identifiable, Sendable
{
  enum Availability: String, Codable { case available, unavailable }
  var id: String                 // Private Git directory, stable across moves.
  var repositoryID: String       // Common Git directory, shared by worktrees.
  var path: String
  var branch: String?
  var head: String?
  var isPrimary: Bool
  var isLocked = false
  var availability: Availability
  var metadataPath: String? = nil
  var privateDirectory: String { metadataPath ?? id }

  var folder: String { URL(fileURLWithPath: path).lastPathComponent }
  var title: String {
    if let branch { return "\(folder)/\(branch)" }
    if let head { return "\(folder)/HEAD@\(head.prefix(7))" }
    return folder
  }
}

struct WorktreeInventory: Equatable, Sendable
{
  var repositoryID: String
  var records: [WorktreeRecord]
  var primary: WorktreeRecord? { records.first { $0.isPrimary } }
}

struct WorktreeBinding: Codable, Equatable, Sendable
{
  var record: WorktreeRecord
  var additionalSession = false
  var isPinnedPrimary: Bool { record.isPrimary && !additionalSession }
}

struct WorktreeTabState: Equatable
{
  var sessionID: UUID
  var binding: WorktreeBinding
  var terminalRunning = false
  var operationBusy = false
  var dirty = false
}

enum WorktreePolicy
{
  enum Removal: Equatable {
    case retain, unavailable, removedWithWork, close
  }
  enum Transition: Equatable {
    case unchanged, deferred, unavailable
    case useSession(UUID)
    case create(additional: Bool)
  }

  static func preferred(_ id: String, in tabs: [WorktreeTabState]) -> UUID?
  {
    let matching = tabs.filter { $0.binding.record.id == id }
    return (matching.first { !$0.binding.additionalSession } ?? matching.first)?
      .sessionID
  }

  static func removal(of tab: WorktreeTabState,
                      inventory: WorktreeInventory?, metadataExists: Bool,
                      pathExists: Bool) -> Removal
  {
    guard let inventory,
          inventory.repositoryID == tab.binding.record.repositoryID
    else { return .unavailable }
    if let current = inventory.records.first(where: {
      $0.id == tab.binding.record.id
    }) {
      return current.availability == .available ? .retain : .unavailable
    }
    // A private metadata directory name can be reused after removal. Its new
    // filesystem incarnation is a different worktree, never the retained one.
    let replaced = inventory.records.contains {
      $0.privateDirectory == tab.binding.record.privateDirectory &&
      $0.id != tab.binding.record.id
    }
    // Existing data/metadata without a confirmed replacement is unavailable.
    guard !tab.binding.record.isPrimary,
          replaced || (!metadataExists && !pathExists)
    else { return .unavailable }
    guard !tab.terminalRunning, !tab.operationBusy, !tab.dirty
    else { return .removedWithWork }
    return .close
  }

  static func transition(from source: WorktreeTabState, to target: WorktreeRecord,
                         tabs: [WorktreeTabState]) -> Transition
  {
    guard target.repositoryID == source.binding.record.repositoryID,
          target.availability == .available else { return .unavailable }
    guard target.id != source.binding.record.id else { return .unchanged }
    guard !source.operationBusy else { return .deferred }
    let matching = tabs.filter { $0.binding.record.id == target.id }
    if let vacant = matching.first(where: {
      !$0.terminalRunning && !$0.operationBusy
    }) {
      return .useSession(vacant.sessionID)
    }
    return .create(additional: !matching.isEmpty)
  }

  static func primaryFirst(_ tabs: [WorktreeTabState]) -> [WorktreeTabState]
  {
    var result = tabs
    // Move only pinned primaries; retain ordering of all other sessions.
    for repo in tabs.map({ $0.binding.record.repositoryID }).uniqued() {
      guard let first = result.firstIndex(where: {
        $0.binding.record.repositoryID == repo
      }), let primary = result.firstIndex(where: {
        $0.binding.record.repositoryID == repo && $0.binding.isPinnedPrimary
      }), primary != first else { continue }
      let tab = result.remove(at: primary)
      result.insert(tab, at: first)
    }
    return result
  }

  static func colorIndex(repositoryID: String, paletteCount: Int) -> Int
  {
    guard paletteCount > 0 else { return 0 }
    var hash: UInt64 = 14695981039346656037
    for byte in repositoryID.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return Int(hash % UInt64(paletteCount))
  }
}

private extension Array where Element: Hashable
{
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

@MainActor
protocol WorktreeTerminalHost: AnyObject
{
  associatedtype Terminal: AnyObject
  var terminalForTransfer: Terminal { get }
  var transferIsBlocked: Bool { get }
  var terminalIsRunning: Bool { get }
  func replaceTerminalForTransfer(_ terminal: Terminal)
}

enum WorktreeTerminalTransfer
{
  enum Failure: Error, Equatable {
    case sameHost, sourceBusy, destinationBusy, occupiedDestination
  }

  @MainActor
  static func perform<Host: WorktreeTerminalHost>(
      from source: Host, to destination: Host, replacement: Host.Terminal) throws
  {
    guard source !== destination else { throw Failure.sameHost }
    guard !source.transferIsBlocked else { throw Failure.sourceBusy }
    guard !destination.transferIsBlocked else { throw Failure.destinationBusy }
    guard !destination.terminalIsRunning else { throw Failure.occupiedDestination }
    // Preflight all failure paths before changing ownership. Strong references
    // keep both panels alive across detach/adopt; no stop/terminate API is used.
    let moving = source.terminalForTransfer
    let unused = destination.terminalForTransfer
    source.replaceTerminalForTransfer(replacement)
    destination.replaceTerminalForTransfer(moving)
    withExtendedLifetime(unused) {}
  }
}

struct WorktreeRestoreItem: Equatable
{
  var sessionID: UUID
  var binding: WorktreeBinding
  var terminalDirectory: String?
}

extension WorktreePolicy
{
  static func restore(_ candidates: [WorktreeRestoreItem],
                      inventories: [String: WorktreeInventory],
                      makeID: () -> UUID = UUID.init) -> [WorktreeRestoreItem]
  {
    var restored: [WorktreeRestoreItem] = []
    var preferredIDs = Set<String>()
    for var candidate in candidates {
      guard candidate.binding.record.availability == .available else { continue }
      if !candidate.binding.additionalSession {
        candidate.binding.additionalSession = !preferredIDs.insert(
            candidate.binding.record.id).inserted
      }
      restored.append(candidate)
    }
    var repoIDs = Set<String>()
    for item in restored { repoIDs.insert(item.binding.record.repositoryID) }
    for repoID in repoIDs.sorted() {
      if restored.contains(where: {
        $0.binding.record.repositoryID == repoID && $0.binding.isPinnedPrimary
      }) { continue }
      guard let primary = inventories[repoID]?.primary,
            primary.availability == .available else { continue }
      let item = WorktreeRestoreItem(sessionID: makeID(),
          binding: .init(record: primary), terminalDirectory: nil)
      let first = restored.firstIndex {
        $0.binding.record.repositoryID == repoID
      } ?? restored.endIndex
      restored.insert(item, at: first)
    }
    let order = primaryFirst(restored.map {
      WorktreeTabState(sessionID: $0.sessionID, binding: $0.binding)
    }).map(\.sessionID)
    let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return restored.sorted { positions[$0.sessionID]! < positions[$1.sessionID]! }
  }
}

struct RepositoryColorAssignments: Codable, Equatable
{
  var automatic: [String: Int] = [:]
  var overrides: [String: Int] = [:]

  mutating func index(for repositoryID: String, count: Int) -> Int
  {
    guard count > 0 else { return 0 }
    if let override = overrides[repositoryID], (0..<count).contains(override) {
      return override
    }
    if let existing = automatic[repositoryID], (0..<count).contains(existing) {
      return existing
    }
    let used = Set(automatic.values).union(overrides.values)
    let start = WorktreePolicy.colorIndex(repositoryID: repositoryID,
                                          paletteCount: count)
    let chosen = (0..<count).map { (start + $0) % count }
      .first { !used.contains($0) } ?? start
    automatic[repositoryID] = chosen
    return chosen
  }
}

enum WorktreeClosePolicy
{
  enum Decision: Equatable { case allow, confirm, cancel }
  static func decision(runningTerminal: Bool, busyOperation: Bool,
                       terminationApproved: Bool = false,
                       confirmation: Bool? = nil) -> Decision
  {
    guard !terminationApproved, runningTerminal || busyOperation else { return .allow }
    guard let confirmation else { return .confirm }
    return confirmation ? .allow : .cancel
  }
}
