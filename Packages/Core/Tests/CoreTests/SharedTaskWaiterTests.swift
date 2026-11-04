import CoreTestSupport
import Testing

@testable import Core

@Test func cancellingOneSharedTaskWaiterDoesNotCancelTheTaskOrOtherWaiters() async throws {
  let entered = TestEvent()
  let release = TestEvent()
  defer { release.signal() }
  let shared = Task<Int, Error> {
    entered.signal()
    try await release.wait()
    #expect(!Task.isCancelled)
    return 42
  }
  let first = Task { try await SharedTaskWaiter.value(of: shared) }
  let second = Task { try await SharedTaskWaiter.value(of: shared) }
  try await entered.wait()
  first.cancel()
  await #expect(throws: CancellationError.self) { _ = try await first.value }
  #expect(!shared.isCancelled)
  #expect(!release.isSignaled)
  release.signal()
  #expect(try await second.value == 42)
  #expect(try await shared.value == 42)
}

@Test func sharedTaskWaiterPreservesFailureAndAlreadyCompletedResult() async throws {
  enum Failure: Error { case expected }
  let failure = Task<Int, Error> { throw Failure.expected }
  await #expect(throws: Failure.self) { _ = try await SharedTaskWaiter.value(of: failure) }
  let success = Task<Int, Error> { 7 }
  #expect(try await success.value == 7)
  #expect(try await SharedTaskWaiter.value(of: success) == 7)
}
