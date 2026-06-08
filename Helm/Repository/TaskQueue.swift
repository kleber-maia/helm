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

  private func increment()
  {
    lock.withLock {
      queueCount += 1
    }
    busyValuePublisher.value = true
  }

  private func decrement()
  {
    lock.withLock {
      queueCount -= 1
      busyValuePublisher.value = queueCount > 0
    }
  }

  public func executeTask(_ block: () -> Void)
  {
    increment()
    block()
    decrement()
  }

  public func executeOffMainThread(_ block: @escaping @Sendable () -> Void)
  {
    if Thread.isMainThread {
      if !isShutDown {
        queue.async {
          [weak self] in
          self?.executeTask(block)
        }
      }
    }
    else {
      executeTask(block)
    }
  }

  /// Runs an asynchronous block serially, tracking busy state.
  /// The block runs in a detached Task so it can safely `await`
  /// `@MainActor` code without deadlocking the serial dispatch queue.
  public func executeAsync(_ block: @Sendable @escaping () async -> Void)
  {
    lock.withLock {
      guard !isShutDown
      else { return }

      let previousTask = asyncTail

      asyncTail = Task.detached(priority: .userInitiated) {
        [weak self] in
        await previousTask?.value
        guard let self
        else { return }
        guard !self.lock.withLock({ self.isShutDown })
        else { return }

        self.increment()
        defer { self.decrement() }
        await block()
      }
    }
  }

  /// Runs an asynchronous block immediately, tracking busy state.
  public func executeDetached(_ block: @Sendable @escaping () async -> Void)
  {
    guard !lock.withLock({ isShutDown })
    else { return }
    Task.detached(priority: .userInitiated) {
      [weak self] in
      guard let self
      else { return }
      self.increment()
      defer { self.decrement() }
      await block()
    }
  }

  /// Runs the block synchronously on the task queue when called from the main
  /// thread, or inline otherwise.
  public func syncOffMainThread<T>(_ block: () throws -> T) throws -> T
  {
    if Thread.isMainThread {
      if isShutDown {
        throw Error.queueShutDown
      }
      else {
        return try queue.sync(execute: block)
      }
    }
    else {
      return try block()
    }
  }
  
  public func wait()
  {
    WaitForQueue(queue)
  }
  
  public func shutDown()
  {
    isShutDown = true
  }
}
