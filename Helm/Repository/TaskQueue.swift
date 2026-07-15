import Foundation
import Combine

/// Runs repository work serially off the main thread and tracks whether it
/// is busy.
public final class TaskQueue: @unchecked Sendable
{
  /// Ingress queue for file-system events. Event handlers resubmit repository
  /// work through `enqueueSerial` so this queue never forms a second Git lane.
  public let queue: DispatchQueue
  private var queueCount: UInt = 0
  private var nextTaskID: UInt64 = 0
  private var isShutDown = false
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

  @discardableResult
  private func enqueueSerial(
    taskID: UInt64,
    kind: String,
    _ block: @Sendable @escaping () async -> Void
  ) -> Bool
  {
    lock.withLock {
      guard !isShutDown
      else {
        repoLogger.publicError("""
            queue drop id=\(taskID) kind=\(kind) label=\(self.queue.label) \
            reason=shutDown
            """)
        return false
      }

      let previousTask = asyncTail
      repoLogger.publicDebug("""
          queue enqueue id=\(taskID) kind=\(kind) label=\(self.queue.label)
          """)

      asyncTail = Task.detached(priority: .userInitiated) {
        [weak self] in
        await previousTask?.value
        guard let self,
              !self.lock.withLock({ self.isShutDown })
        else { return }

        let started = Date()
        self.increment(taskID: taskID, kind: kind)
        defer {
          self.decrement(taskID: taskID, kind: kind, started: started)
        }
        await block()
      }
      return true
    }
  }

  public func executeTask(_ block: @Sendable @escaping () -> Void)
  {
    executeOffMainThread(block)
  }

  public func executeOffMainThread(_ block: @escaping @Sendable () -> Void)
  {
    let taskID = makeTaskID()

    enqueueSerial(taskID: taskID, kind: "sync") {
      block()
    }
  }

  /// Runs an asynchronous block serially, tracking busy state.
  /// The block runs in a detached Task so it can safely `await`
  /// `@MainActor` code without deadlocking the serial dispatch queue.
  public func executeAsync(_ block: @Sendable @escaping () async -> Void)
  {
    let taskID = makeTaskID()

    enqueueSerial(taskID: taskID, kind: "async", block)
  }

  /// Runs an asynchronous block on the repository's serial task lane.
  public func executeDetached(_ block: @Sendable @escaping () async -> Void)
  {
    let taskID = makeTaskID()

    enqueueSerial(taskID: taskID, kind: "detached", block)
  }

  public func wait()
  {
    WaitForQueue(queue)
    let tail = lock.withLock { asyncTail }

    guard let tail
    else { return }

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await tail.value
      semaphore.signal()
    }
    wait(for: semaphore)
  }

  private func wait(for semaphore: DispatchSemaphore)
  {
    if Thread.isMainThread {
      while semaphore.wait(timeout: .now()) != .success {
        _ = RunLoop.current.run(mode: .default,
                                before: Date(timeIntervalSinceNow: 0.01))
      }
    }
    else {
      semaphore.wait()
    }
  }
  
  public func shutDown()
  {
    repoLogger.publicInfo("queue shutDown label=\(self.queue.label)")
    lock.withLock {
      isShutDown = true
    }
  }
}
