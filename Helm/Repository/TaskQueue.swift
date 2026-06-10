import Foundation
import Combine

/// Uses a `DispatchQueue` to run tasks off the main thread, and tracks whether
/// it is busy.
public final class TaskQueue: @unchecked Sendable
{
  public enum Error: Swift.Error
  {
    /// Attempt to operate on a queue that is shut down
    case queueShutDown
  }

  public let queue: DispatchQueue
  private var queueCount: UInt = 0
  private var nextTaskID: UInt64 = 0
  fileprivate(set) var isShutDown = false
  private let lock = NSRecursiveLock()
  private var asyncTail: Task<Void, Never>?

  private let busyValuePublisher = CurrentValueSubject<Bool, Never>(false)
  public var busyPublisher: AnyPublisher<Bool, Never>
  { busyValuePublisher.eraseToAnyPublisher() }
  public var isBusy: Bool
  { lock.withLock { queueCount > 0 } }
  
  init(id: String)
  {
    self.queue = DispatchQueue(label: id, attributes: [])
  }

  private func makeTaskID() -> UInt64
  {
    return lock.withLock {
      nextTaskID += 1
      return nextTaskID
    }
  }

  private func increment(taskID: UInt64, kind: String)
  {
    let count = lock.withLock {
      queueCount += 1
      return queueCount
    }

    repoLogger.publicDebug("""
        queue start id=\(taskID) kind=\(kind) label=\(self.queue.label) \
        pending=\(count)
        """)
    busyValuePublisher.value = true
  }

  private func decrement(taskID: UInt64, kind: String, started: Date)
  {
    let count = lock.withLock {
      if queueCount > 0 {
        queueCount -= 1
      }
      return queueCount
    }

    repoLogger.publicDebug("""
        queue finish id=\(taskID) kind=\(kind) label=\(self.queue.label) \
        pending=\(count) duration=\(Date().timeIntervalSince(started))
        """)
    lock.withLock {
      busyValuePublisher.value = queueCount > 0
    }
  }

  private func executeTask(
    id taskID: UInt64,
    kind: String,
    _ block: () -> Void
  )
  {
    let started = Date()

    increment(taskID: taskID, kind: kind)
    block()
    decrement(taskID: taskID, kind: kind, started: started)
  }

  public func executeTask(_ block: () -> Void)
  {
    let taskID = makeTaskID()

    repoLogger.publicDebug("""
        queue enqueue id=\(taskID) kind=direct label=\(self.queue.label)
        """)
    executeTask(id: taskID, kind: "direct", block)
  }

  public func executeOffMainThread(_ block: @escaping @Sendable () -> Void)
  {
    let taskID = makeTaskID()

    repoLogger.publicDebug("""
        queue enqueue id=\(taskID) kind=sync label=\(self.queue.label) \
        fromMain=\(Thread.isMainThread)
        """)
    if Thread.isMainThread {
      if !isShutDown {
        queue.async {
          [weak self] in
          self?.executeTask(id: taskID, kind: "sync", block)
        }
      }
      else {
        repoLogger.publicError("""
            queue drop id=\(taskID) kind=sync label=\(self.queue.label) \
            reason=shutDown
            """)
      }
    }
    else {
      executeTask(id: taskID, kind: "sync-inline", block)
    }
  }

  /// Runs an asynchronous block serially, tracking busy state.
  /// The block runs in a detached Task so it can safely `await`
  /// `@MainActor` code without deadlocking the serial dispatch queue.
  public func executeAsync(_ block: @Sendable @escaping () async -> Void)
  {
    let taskID = makeTaskID()

    lock.withLock {
      guard !isShutDown
      else {
        repoLogger.publicError("""
            queue drop id=\(taskID) kind=async label=\(self.queue.label) \
            reason=shutDown
            """)
        return
      }

      let previousTask = asyncTail
      repoLogger.publicDebug("""
          queue enqueue id=\(taskID) kind=async label=\(self.queue.label)
          """)

      asyncTail = Task.detached(priority: .userInitiated) {
        [weak self] in
        await previousTask?.value
        guard let self
        else { return }
        guard !self.lock.withLock({ self.isShutDown })
        else {
          repoLogger.publicError("""
              queue drop id=\(taskID) kind=async label=\(self.queue.label) \
              reason=shutDownAfterWait
              """)
          return
        }

        let started = Date()
        self.increment(taskID: taskID, kind: "async")
        defer {
          self.decrement(taskID: taskID, kind: "async", started: started)
        }
        await block()
      }
    }
  }

  /// Runs an asynchronous block immediately, tracking busy state.
  public func executeDetached(_ block: @Sendable @escaping () async -> Void)
  {
    let taskID = makeTaskID()

    guard !lock.withLock({ isShutDown })
    else {
      repoLogger.publicError("""
          queue drop id=\(taskID) kind=detached label=\(self.queue.label) \
          reason=shutDown
          """)
      return
    }
    repoLogger.publicDebug("""
        queue enqueue id=\(taskID) kind=detached label=\(self.queue.label)
        """)
    Task.detached(priority: .userInitiated) {
      [weak self] in
      guard let self
      else { return }
      let started = Date()
      self.increment(taskID: taskID, kind: "detached")
      defer {
        self.decrement(taskID: taskID, kind: "detached", started: started)
      }
      await block()
    }
  }

  /// Runs the block synchronously on the task queue when called from the main
  /// thread, or inline otherwise.
  public func syncOffMainThread<T>(_ block: () throws -> T) throws -> T
  {
    let taskID = makeTaskID()

    repoLogger.publicDebug("""
        queue sync request id=\(taskID) label=\(self.queue.label) \
        fromMain=\(Thread.isMainThread)
        """)
    if Thread.isMainThread {
      if isShutDown {
        repoLogger.publicError("""
            queue sync drop id=\(taskID) label=\(self.queue.label) \
            reason=shutDown
            """)
        throw Error.queueShutDown
      }
      else {
        return try queue.sync {
          let started = Date()

          repoLogger.publicDebug("""
              queue sync start id=\(taskID) label=\(self.queue.label)
              """)
          defer {
            repoLogger.publicDebug("""
                queue sync finish id=\(taskID) label=\(self.queue.label) \
                duration=\(Date().timeIntervalSince(started))
                """)
          }
          return try block()
        }
      }
    }
    else {
      let started = Date()

      repoLogger.publicDebug("""
          queue sync inline start id=\(taskID) label=\(self.queue.label)
          """)
      defer {
        repoLogger.publicDebug("""
            queue sync inline finish id=\(taskID) label=\(self.queue.label) \
            duration=\(Date().timeIntervalSince(started))
            """)
      }
      return try block()
    }
  }
  
  public func wait()
  {
    WaitForQueue(queue)
  }
  
  public func shutDown()
  {
    repoLogger.publicInfo("queue shutDown label=\(self.queue.label)")
    isShutDown = true
  }
}
