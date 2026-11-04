import Foundation
import Testing

@testable import ADB

private final class FakeUSBRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (@Sendable (Result<Int, Error>) -> Void)?
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var started = false
  private(set) var abortCount = 0
  func enqueue(_ completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
    lock.lock()
    self.completion = completion
    started = true
    let waiter = startedWaiter
    startedWaiter = nil
    lock.unlock()
    waiter?.resume()
  }
  func waitStarted() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if started {
        lock.unlock()
        continuation.resume()
      } else {
        startedWaiter = continuation
        lock.unlock()
      }
    }
  }
  func abort() {
    lock.lock()
    abortCount += 1
    let callback = completion
    lock.unlock()
    callback?(.failure(CancellationError()))
    callback?(.success(100))
  }
  func succeed() {
    lock.lock()
    let callback = completion
    lock.unlock()
    callback?(.success(7))
    callback?(.success(8))
  }
}

@Test func usbAsyncCancellationAbortsAndIgnoresDuplicateCompletion() async throws {
  let fake = FakeUSBRequest()
  let request = USBIORequest(enqueue: fake.enqueue, abort: fake.abort)
  let task = Task { try await request.run() }
  await fake.waitStarted()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(fake.abortCount == 1)
}

@Test func usbAsyncCompletionReturnsOnce() async throws {
  let fake = FakeUSBRequest()
  let request = USBIORequest(enqueue: fake.enqueue, abort: fake.abort)
  let task = Task { try await request.run() }
  await fake.waitStarted()
  fake.succeed()
  #expect(try await task.value == 7)
}

@Test func usbAsyncCancelledBeforeStartDoesNotEnqueue() async throws {
  let request = USBIORequest(enqueue: { _ in Issue.record("取消后不应发起 USB 请求") }, abort: {})
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await request.run()
  }
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func usbAsyncEnqueueFailureReturnsError() async throws {
  let request = USBIORequest(enqueue: { _ in throw CocoaError(.fileReadUnknown) }, abort: {})
  await #expect(throws: CocoaError.self) { try await request.run() }
}
