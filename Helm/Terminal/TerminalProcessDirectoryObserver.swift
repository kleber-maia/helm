import Foundation

/// Samples only our child shell, in response to its output. There is no idle
/// timer and no search through other processes or foreground descendants.
final class TerminalProcessDirectoryObserver: @unchecked Sendable
{
  private let pid: pid_t
  private let identity: HelmProcessIdentity
  private let changed: @MainActor @Sendable (URL) -> Void
  private let queue = DispatchQueue(label: "helm.process-cwd", qos: .utility)
  private let lock = NSLock()
  private var stopped = false
  private var pending = false
  private var eventGeneration = 0
  private var lastPath: String?
  private var lastDirectory: HelmDirectoryIdentity?

  init?(pid: pid_t, changed: @escaping @MainActor @Sendable (URL) -> Void)
  {
    var identity = HelmProcessIdentity()
    guard HelmOwnedProcessIdentity(pid, &identity) else { return nil }
    self.pid = pid
    self.identity = identity
    self.changed = changed
  }

  func outputReceived()
  {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    eventGeneration += 1
    guard !pending else { return }
    pending = true
    scheduleSample()
  }

  func stop()
  {
    lock.withLock { stopped = true }
  }

  private func scheduleSample()
  {
    queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.sample() }
  }

  private func sample()
  {
    let generation: Int? = lock.withLock {
      stopped ? nil : eventGeneration
    }
    guard let generation else { return }
    var buffer = [CChar](repeating: 0, count: 4096)
    var directoryIdentity = HelmDirectoryIdentity()
    let success = HelmOwnedProcessDirectoryInfo(pid, identity, &buffer,
                                                buffer.count, &directoryIdentity)
    let path = success ? String(cString: buffer) : nil
    let publish: Bool = lock.withLock {
      guard !stopped else { return false }
      // Retain an event that arrived while the process query was in flight.
      if generation != eventGeneration { scheduleSample() }
      else { pending = false }
      guard let path else { return false }
      if path == lastPath, directoryIdentity.device == lastDirectory?.device,
         directoryIdentity.inode == lastDirectory?.inode { return false }
      lastPath = path
      lastDirectory = directoryIdentity
      return true
    }
    if publish, let path {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.lock.withLock({ !self.stopped }) else { return }
        self.changed(directory)
      }
    }
  }
}
