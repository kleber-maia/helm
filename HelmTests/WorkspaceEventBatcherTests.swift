import XCTest

final class WorkspaceEventBatcherTests: XCTestCase
{
  func testBurstMergesAndDeduplicatesPaths()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    batcher.receive(["b", "a"])
    batcher.receive(["a", "c"])
    XCTAssertTrue(batches.isEmpty)
    XCTAssertEqual(clock.scheduledCount, 1)

    clock.advance(by: 0.25)
    XCTAssertEqual(batches, [["a", "b", "c"]])
  }

  func testDeliveryWaitsForWindow()
  {
    for delay in [0.25, 1.0] {
      let clock = ManualScheduler()
      var batches: [[String]] = []
      let batcher = WorkspaceEventBatcher(
          delay: delay, schedule: clock.schedule) {
        batches.append($0)
      }

      batcher.receive(["a"])
      clock.advance(by: delay - 0.001)
      XCTAssertTrue(batches.isEmpty, "\(delay) s window")
      clock.advance(by: 0.001)
      XCTAssertEqual(batches, [["a"]], "\(delay) s window")
    }
  }

  func testLaterEventsDoNotRestartDeadline()
  {
    for delay in [0.25, 1.0] {
      let clock = ManualScheduler()
      var batches: [[String]] = []
      let batcher = WorkspaceEventBatcher(
          delay: delay, schedule: clock.schedule) {
        batches.append($0)
      }

      batcher.receive(["first"])
      clock.advance(by: delay * 0.75)
      batcher.receive(["later"])
      clock.advance(by: delay * 0.25)
      XCTAssertEqual(batches, [["first", "later"]], "\(delay) s window")
    }
  }

  func testContinuousEventsDoNotStarveDelivery()
  {
    for delay in [0.25, 1.0] {
      let clock = ManualScheduler()
      var batches: [[String]] = []
      let batcher = WorkspaceEventBatcher(
          delay: delay, schedule: clock.schedule) {
        batches.append($0)
      }

      for index in 0..<14 {
        batcher.receive(["file\(index)"])
        clock.advance(by: delay / 4)
      }
      XCTAssertEqual(batches.count, 3, "Refresh while writes continue")
      clock.advance(by: delay / 2)
      XCTAssertEqual(batches.count, 4, "Publish the trailing batch")
      XCTAssertEqual(Set(batches.flatMap { $0 }),
                     Set((0..<14).map { "file\($0)" }))
    }
  }

  func testLaterBatchHasItsOwnWindowAndNoOldPaths()
  {
    for delay in [0.25, 1.0] {
      let clock = ManualScheduler()
      var batches: [[String]] = []
      let batcher = WorkspaceEventBatcher(
          delay: delay, schedule: clock.schedule) {
        batches.append($0)
      }

      batcher.receive(["first"])
      clock.advance(by: delay)
      batcher.receive(["second"])
      clock.advance(by: delay - 0.001)
      XCTAssertEqual(batches, [["first"]], "\(delay) s window")
      clock.advance(by: 0.001)
      XCTAssertEqual(batches, [["first"], ["second"]], "\(delay) s window")
    }
  }

  func testFullRescanDominatesPathsBeforeAndAfterIt()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    batcher.receive(["before"])
    batcher.receive([])
    batcher.receive(["after"])
    clock.advance(by: 0.25)
    XCTAssertEqual(batches, [[]])

    batcher.receive(["next"])
    clock.advance(by: 0.25)
    XCTAssertEqual(batches, [[], ["next"]])
  }

  func testEmptyRescanBypassesIgnorePredicate()
  {
    let result = WorkspaceEventBatcher.relevantPaths(
        [], skipIgnored: true) { _ in
      XCTFail("Full rescan must not inspect paths")
      return true
    }
    XCTAssertEqual(result, [])
  }

  func testIgnoredOnlyBatchIsSuppressed()
  {
    let repository = FakeIgnoreRules()
    XCTAssertNil(WorkspaceEventBatcher.relevantPaths(
        ["ignored/a", "ignored/b"], skipIgnored: true,
        isIgnored: repository.isIgnored))
  }

  func testMixedBatchRetainsRelevantPaths()
  {
    let repository = FakeIgnoreRules()
    XCTAssertEqual(WorkspaceEventBatcher.relevantPaths(
        ["ignored/a", "visible", "ignored/b"], skipIgnored: true,
        isIgnored: repository.isIgnored), ["visible"])
  }

  func testIgnoreFilteringCanBeDisabled()
  {
    let result = WorkspaceEventBatcher.relevantPaths(
        ["ignored/a"], skipIgnored: false) { _ in
      XCTFail("Disabled ignore filtering must not inspect paths")
      return true
    }
    XCTAssertEqual(result, ["ignored/a"])
  }

  func testStopCancelsPendingAndRejectsLaterEvents()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    batcher.receive(["before-stop"])
    batcher.stop()
    batcher.stop()
    batcher.receive(["after-stop"])
    clock.advance(by: 1)
    XCTAssertTrue(batches.isEmpty)
    XCTAssertEqual(clock.scheduledCount, 1)
    XCTAssertEqual(clock.cancelledCount, 1)
  }

  func testStopCancelsAlreadyDueButUndeliveredWork()
  {
    for delay in [0.25, 1.0] {
      let clock = ManualScheduler()
      var batches: [[String]] = []
      let batcher = WorkspaceEventBatcher(
          delay: delay, schedule: clock.schedule) {
        batches.append($0)
      }

      batcher.receive(["queued"])
      clock.elapseWithoutRunning(by: delay * 2)
      batcher.stop()
      clock.runReady()
      XCTAssertTrue(batches.isEmpty, "\(delay) s window")
    }
  }

  func testPendingDeliveryDoesNotRetainBatcher()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    var batcher: WorkspaceEventBatcher? =
        WorkspaceEventBatcher(schedule: clock.schedule) {
          batches.append($0)
        }
    let reference = WeakBatcher(batcher)

    batcher?.receive(["pending"])
    batcher = nil
    XCTAssertNil(reference.value)
    clock.advance(by: 1)
    XCTAssertTrue(batches.isEmpty)
    XCTAssertEqual(clock.cancelledCount, 1)
  }

  func testReentrantEventStartsNextBatch()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    var batcher: WorkspaceEventBatcher!
    batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
      if batches.count == 1 {
        batcher.receive(["reentrant"])
      }
    }
    defer { batcher.stop(); batcher = nil }

    batcher.receive(["first"])
    clock.advance(by: 0.25)
    XCTAssertEqual(batches, [["first"]])
    clock.advance(by: 0.25)
    XCTAssertEqual(batches, [["first"], ["reentrant"]])
  }

  func testReentrantStopCancelsNextBatch()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    var batcher: WorkspaceEventBatcher!
    batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
      batcher.receive(["next"])
      batcher.stop()
    }
    defer { batcher = nil }

    batcher.receive(["first"])
    clock.advance(by: 1)
    XCTAssertEqual(batches, [["first"]])
  }

  func testBusyDeliveryQueueKeepsOnePendingBatchWithoutPathLoss()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    for index in 0..<100 {
      batcher.receive(["file\(index)"])
      clock.elapseWithoutRunning(by: 0.01)
    }
    XCTAssertEqual(clock.scheduledCount, 1)
    XCTAssertTrue(batches.isEmpty)
    clock.runReady()
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(Set(batches[0]), Set((0..<100).map { "file\($0)" }))
  }

  func testConcurrentIngressPreservesAllPathsInOneBatch()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    DispatchQueue.concurrentPerform(iterations: 100) {
      batcher.receive(["file\($0)"])
    }
    XCTAssertEqual(clock.scheduledCount, 1)
    clock.advance(by: 0.25)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(Set(batches[0]), Set((0..<100).map { "file\($0)" }))
  }

  func testConcurrentStopAndIngressCannotDeliverAfterStop()
  {
    let clock = ManualScheduler()
    var batches: [[String]] = []
    let batcher = WorkspaceEventBatcher(schedule: clock.schedule) {
      batches.append($0)
    }

    DispatchQueue.concurrentPerform(iterations: 100) { index in
      if index.isMultiple(of: 7) { batcher.stop() }
      else { batcher.receive(["file\(index)"]) }
    }
    clock.advance(by: 1)
    XCTAssertTrue(batches.isEmpty)
    batcher.receive(["after-all-stops"])
    clock.advance(by: 1)
    XCTAssertTrue(batches.isEmpty)
  }

  func testDefaultSchedulerDeliversOnMainQueue()
  {
    let delivered = expectation(description: "main-queue delivery")
    let batcher = WorkspaceEventBatcher {
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual($0, ["event"])
      delivered.fulfill()
    }

    batcher.receive(["event"])
    wait(for: [delivered], timeout: 5)
    batcher.stop()
  }
}

private final class WeakBatcher
{
  weak var value: WorkspaceEventBatcher?

  init(_ value: WorkspaceEventBatcher?)
  {
    self.value = value
  }
}

private final class FakeIgnoreRules
{
  func isIgnored(_ path: String) -> Bool
  { path.hasPrefix("ignored/") }
}

/// Virtual time and withheld delivery model deadlines and a busy main queue.
private final class ManualScheduler
{
  private struct Entry
  {
    let deadline: TimeInterval
    let work: DispatchWorkItem
  }

  private let lock = NSLock()
  private var now: TimeInterval = 0
  private var entries: [Entry] = []
  private var history: [DispatchWorkItem] = []

  var scheduledCount: Int { lock.withLock { history.count } }
  var cancelledCount: Int
  { lock.withLock { history.filter { $0.isCancelled }.count } }

  func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem)
  {
    lock.withLock {
      entries.append(Entry(deadline: now + delay, work: work))
      history.append(work)
    }
  }

  func advance(by interval: TimeInterval)
  {
    let target = lock.withLock { now + interval }
    while let next = takeReady(before: target) {
      next.perform()
    }
    lock.withLock { now = target }
  }

  func elapseWithoutRunning(by interval: TimeInterval)
  {
    lock.withLock { now += interval }
  }

  func runReady()
  {
    let target = lock.withLock { now }
    while let next = takeReady(before: target) {
      next.perform()
    }
  }

  private func takeReady(before target: TimeInterval) -> DispatchWorkItem?
  {
    lock.withLock {
      guard let index = entries.indices.min(by: {
        entries[$0].deadline < entries[$1].deadline
      }), entries[index].deadline <= target
      else { return nil }

      let entry = entries.remove(at: index)
      now = max(now, entry.deadline)
      return entry.work
    }
  }
}
