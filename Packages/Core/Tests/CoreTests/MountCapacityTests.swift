import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private final class NativeCapacityGate: Sendable {
  private struct State {
    var started = false
    var observer: CheckedContinuation<Void, Never>?
  }
  private let state = Mutex(State())
  private let gate = DispatchSemaphore(value: 0)

  func read() -> Int64? {
    #expect(!Thread.isMainThread)
    let observer = state.withLock { value in
      value.started = true
      let observer = value.observer
      value.observer = nil
      return observer
    }
    observer?.resume()
    gate.wait()
    return 12345
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { value in
        if value.started { return true }
        value.observer = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func release() { gate.signal() }
}

@MainActor @Test func mountedCapacityQueryRunsOffMainActorAndHasDeadline() async throws {
  let clock = ManualTestClock()
  let gate = NativeCapacityGate()
  defer { gate.release() }
  let completions = AsyncStream<Int64?>.makeStream()
  let request = MountCapacityRequest(clock: clock.deadlineClock)
  let task = Task {
    await request.run(
      read: { gate.read() },
      completed: { value in
        completions.continuation.yield(value)
        completions.continuation.finish()
      })
  }
  await gate.waitUntilStarted()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(RemoteTimeout.deviceRequest))
  #expect(await task.value == nil)
  gate.release()
  var iterator = completions.stream.makeAsyncIterator()
  let late = try #require(await iterator.next())
  #expect(late == 12345)
}

@MainActor @Test func mountedCapacityCompletionDoesNotNeedTimerToExpire() async {
  let clock = ManualTestClock()
  var completed: Int64?
  let value = await MountCapacityRequest(clock: clock.deadlineClock).run(
    read: {
      #expect(!Thread.isMainThread)
      return 42
    }, completed: { completed = $0 })
  #expect(value == 42)
  #expect(completed == 42)
}

@Test func mountedCapacityUnknownAndOverflowAreNotZero() {
  #expect(MountedShare(url: URL(fileURLWithPath: "/fixture")).availableBytes == nil)
  #expect(MountCapacityRequest.bytes(blocks: 3, blockSize: 4096) == 12288)
  #expect(MountCapacityRequest.bytes(blocks: 0, blockSize: 4096) == 0)
  #expect(MountCapacityRequest.bytes(blocks: UInt64.max, blockSize: 4096) == nil)
  #expect(MountCapacityRequest.bytes(blocks: UInt64(Int64.max), blockSize: 4096) == nil)
  #expect(MountCapacityRequest.bytes(blocks: 1, blockSize: 0) == nil)
}
