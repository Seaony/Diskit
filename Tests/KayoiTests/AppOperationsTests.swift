import Core
import CoreTestSupport
import Foundation
import Testing

@MainActor @Test func quittingCancelsPendingWorkWithoutChangingMountedShares() async throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let states = model.connections.states
  let connections = model.connections.connections
  let blocked = TestEvent()
  let started = AsyncStream<Void>.makeStream()
  var cancelled = false
  var authorizationCancelled = 0
  let task = model.operations.start(onCancel: { authorizationCancelled += 1 }) {
    started.continuation.yield(())
    started.continuation.finish()
    do { try await blocked.wait() } catch is CancellationError {
      cancelled = true
    } catch { Issue.record(error) }
  }
  var iterator = started.stream.makeAsyncIterator()
  _ = await iterator.next()
  model.prepareToQuit()
  #expect(authorizationCancelled == 1)
  await task.value
  model.prepareToQuit()
  #expect(cancelled)
  #expect(authorizationCancelled == 1)
  #expect(model.connections.states == states)
  #expect(model.connections.connections == connections)
  var restarted = false
  await model.operations.start { restarted = true }.value
  #expect(!restarted)
}

@MainActor @Test func completedOperationIsNotCancelledAgainOnQuit() async {
  let operations = AppOperations()
  var cancelled = false
  await operations.start(onCancel: { cancelled = true }) {}.value
  operations.cancelAll()
  #expect(!cancelled)
}

@MainActor @Test func quittingWaitsForCancelledWorkToFinishCleanup() async throws {
  let operations = AppOperations()
  let blocked = TestEvent()
  let started = AsyncStream<Void>.makeStream()
  var cleanup: CheckedContinuation<Void, Never>?
  let cleaning = TestEvent()
  _ = operations.start {
    started.continuation.yield(())
    started.continuation.finish()
    do { try await blocked.wait() } catch {
      await withCheckedContinuation {
        cleanup = $0
        cleaning.signal()
      }
    }
  }
  var iterator = started.stream.makeAsyncIterator()
  _ = await iterator.next()
  operations.cancelAll()
  try await cleaning.wait()
  var finished = false
  let joining = TestEvent()
  let quitting = Task {
    joining.signal()
    await operations.finishCancellation()
    finished = true
  }
  try await joining.wait()
  #expect(!finished)
  cleanup?.resume()
  await quitting.value
  #expect(finished)
}

@MainActor @Test func queuedCancellationStillCallsOperationFinish() async {
  let operations = AppOperations()
  var started = false
  var finished = 0
  let task = operations.start(onFinish: { finished += 1 }) { started = true }
  task.cancel()
  await task.value
  #expect(!started)
  #expect(finished == 1)
}

@MainActor @Test func cancellingOneConnectionLeavesOtherOperationsRunning() async throws {
  let operations = AppOperations()
  let first = UUID()
  let second = UUID()
  var cancelled: [UUID] = []
  let entered = [TestEvent(), TestEvent()]
  let blocked = TestEvent()
  let one = operations.start(connectionID: first, onCancel: { cancelled.append(first) }) {
    entered[0].signal()
    try? await blocked.wait()
  }
  let two = operations.start(connectionID: second, onCancel: { cancelled.append(second) }) {
    entered[1].signal()
    try? await blocked.wait()
  }
  try await entered[0].wait()
  try await entered[1].wait()
  operations.cancel(connectionID: first)
  await one.value
  #expect(cancelled == [first])
  #expect(!two.isCancelled)
  operations.cancelAll()
  await two.value
}
