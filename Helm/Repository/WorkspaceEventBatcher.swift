import Foundation

/// Merges workspace notifications before they invalidate caches or reach UI
/// subscribers. The scheduler is injectable so timing can be tested without
/// sleeping; production delivery uses the main queue.
final class WorkspaceEventBatcher
{
  typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void

  private let lock = NSRecursiveLock()
  private let delay: TimeInterval
  private let schedule: Schedule
  private let publish: ([String]) -> Void
  private var paths: Set<String> = []
  private var needsFullRescan = false
  private var pendingFlush: DispatchWorkItem?
  private var isStopped = false

  init(delay: TimeInterval = 0.25,
       schedule: @escaping Schedule = { delay, work in
         DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
       },
       publish: @escaping ([String]) -> Void)
  {
    self.delay = delay
    self.schedule = schedule
    self.publish = publish
  }

  deinit
  {
    stop()
  }

  /// nil means an ignored-only batch. An empty list is a full-rescan request
  /// from FSEvents and must not be dropped by ignored-path filtering.
  static func relevantPaths(_ paths: [String], skipIgnored: Bool,
                            isIgnored: (String) -> Bool) -> [String]?
  {
    guard skipIgnored, !paths.isEmpty
    else { return paths }

    let filtered = paths.filter { !isIgnored($0) }
    return filtered.isEmpty ? nil : filtered
  }

  func receive(_ changedPaths: [String])
  {
    lock.withLock {
      guard !isStopped
      else { return }

      if changedPaths.isEmpty {
        needsFullRescan = true
        paths.removeAll()
      }
      else if !needsFullRescan {
        paths.formUnion(changedPaths)
      }

      guard pendingFlush == nil
      else { return }

      let flush = DispatchWorkItem { [weak self] in
        self?.flush()
      }
      pendingFlush = flush
      // A fixed window from the first event never restarts under sustained
      // writes. Keep it pending until execution, even while main is busy.
      schedule(delay, flush)
    }
  }

  func stop()
  {
    lock.withLock {
      isStopped = true
      pendingFlush?.cancel()
      pendingFlush = nil
      paths.removeAll()
      needsFullRescan = false
    }
  }

  private func flush()
  {
    lock.withLock {
      guard !isStopped, pendingFlush != nil
      else { return }

      let changedPaths = needsFullRescan ? [] : paths.sorted()
      paths.removeAll()
      needsFullRescan = false
      pendingFlush = nil

      // Clearing pending state before delivery permits reentrant events to
      // schedule the next batch. Serialize publication with stop().
      publish(changedPaths)
    }
  }
}
