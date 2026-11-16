import CoreTestSupport
import Foundation
import Testing

@MainActor @Test func recoveryCoalescesEventsWhileAnAttemptIsRunning() async throws {
  let operations = AppOperations()
  var calls = 0
  var active = 0
  var maximum = 0
  let started = [TestEvent(), TestEvent()]
  var completions: [CheckedContinuation<Void, Never>] = []
  let recovery = ConnectionRecovery(operations: operations, refresh: {}) {
    calls += 1
    active += 1
    maximum = max(maximum, active)
    await withCheckedContinuation {
      completions.append($0)
      started[calls - 1].signal()
    }
    active -= 1
  }
  recovery.start()
  recovery.networkChanged(available: true)
  recovery.didWake()
  try await started[0].wait()
  #expect(calls == 1)
  recovery.networkChanged(available: true)
  recovery.didWake()
  recovery.didWake()
  completions.removeFirst().resume()
  try await started[1].wait()
  #expect(calls == 2)
  #expect(maximum == 1)
  recovery.stop()
  completions.removeFirst().resume()
  operations.cancelAll()
  await operations.finishCancellation()
  recovery.didWake()
  recovery.networkChanged(available: true)
  #expect(calls == 2)
}

@MainActor @Test func wakingOfflineWaitsForNetworkBeforeRetrying() async throws {
  let operations = AppOperations()
  let started = TestEvent()
  var refreshes = 0
  var attempts = 0
  let recovery = ConnectionRecovery(operations: operations, refresh: { refreshes += 1 }) {
    attempts += 1
    started.signal()
  }
  recovery.networkChanged(available: false)
  recovery.didWake()
  await Task.yield()
  #expect(attempts == 0)
  #expect(refreshes == 2)
  recovery.networkChanged(available: true)
  try await started.wait()
  #expect(attempts == 1)
  recovery.stop()
  operations.cancelAll()
  await operations.finishCancellation()
}

@MainActor @Test func wakingDuringCancelledAttemptSchedulesOneFreshAttempt() async throws {
  let operations = AppOperations()
  var attempts = 0
  let started = [TestEvent(), TestEvent()]
  let blocked = TestEvent()
  var cancelled = false
  let recovery = ConnectionRecovery(operations: operations, refresh: {}) {
    attempts += 1
    started[attempts - 1].signal()
    if attempts == 1 {
      do { try await blocked.wait() } catch is CancellationError {
        cancelled = true
      } catch { Issue.record(error) }
    }
  }
  recovery.start()
  try await started[0].wait()
  recovery.willSleep()
  recovery.didWake()
  try await started[1].wait()
  #expect(cancelled)
  #expect(attempts == 2)
  recovery.stop()
  operations.cancelAll()
  await operations.finishCancellation()
}

@MainActor @Test func cameraAvailabilityKeepsLocationsAndOnlyUniqueLegacySerials() {
  let identities = AppModel.deviceIdentifiers([
    ("usb:1", "duplicate"), ("usb:2", "duplicate"), ("usb:3", ""), ("usb:4", "unique"),
  ])
  #expect(identities == ["usb:1", "usb:2", "usb:3", "usb:4", "unique"])
}

@MainActor @Test func wakingAfterQueuedAttemptWasCancelledStillRetries() async {
  let operations = AppOperations()
  let attempted = AsyncStream<Void>.makeStream()
  var attempts = 0
  let recovery = ConnectionRecovery(operations: operations, refresh: {}) {
    attempts += 1
    attempted.continuation.yield(())
    attempted.continuation.finish()
  }
  recovery.start()
  recovery.willSleep()
  recovery.didWake()
  var iterator = attempted.stream.makeAsyncIterator()
  _ = await iterator.next()
  #expect(attempts == 1)
  recovery.stop()
  operations.cancelAll()
  await operations.finishCancellation()
}

// 启动时网络监视器的第一次回调不能再触发一轮恢复，否则自动挂载失败会通知两次
@MainActor @Test func firstNetworkReportOnlyRecordsThePath() async throws {
  let operations = AppOperations()
  let started = [TestEvent(), TestEvent()]
  var attempts = 0
  var refreshes = 0
  let recovery = ConnectionRecovery(operations: operations, refresh: { refreshes += 1 }) {
    attempts += 1
    started[attempts - 1].signal()
  }
  recovery.start()
  recovery.networkChanged(available: true)
  try await started[0].wait()
  for _ in 0..<10 { await Task.yield() }
  #expect(attempts == 1)
  #expect(refreshes == 0)
  recovery.networkChanged(available: false)
  recovery.networkChanged(available: true)
  try await started[1].wait()
  #expect(attempts == 2)
  #expect(refreshes == 2)
  recovery.stop()
  operations.cancelAll()
  await operations.finishCancellation()
}
