import CoreTestSupport
import Foundation
import Testing

@testable import CameraUSB
@testable import Core

@MainActor @Test func cameraPhasesUseRemainingDeadline() async throws {
  let clock = ManualTestClock()
  let deadline = clock.now.advanced(by: .seconds(15))
  let firstCall = CameraCall<Int>(
    now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
  let first = try await firstCall.run(until: deadline) { complete in
    clock.advance(by: .seconds(8))
    complete(.success(1))
  }
  #expect(first == 1)
  let started = TestEvent()
  let secondCall = CameraCall<Int>(
    now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
  let second = Task { @MainActor in
    try await secondCall.run(until: deadline) { _ in started.signal() }
  }
  try await started.wait()
  clock.advance(by: .seconds(7))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await second.value }
  #expect(clock.pendingSleepCount == 0)
}

@MainActor @Test func expiredCameraPhaseNeverStartsNativeWork() async throws {
  let clock = ManualTestClock()
  let call = CameraCall<Int>(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
  var started = false
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    _ = try await call.run(until: clock.now.advanced(by: .seconds(-1))) { _ in
      started = true
    }
  }
  #expect(!started)
}
