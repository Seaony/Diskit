import CoreTestSupport
import Foundation
import Testing

@testable import Core

@MainActor @Test func cameraCallCompletesOnceAndPreservesFailure() async throws {
  let clock = ManualTestClock()
  let call = CameraCall<Int>(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
  #expect(
    try await call.run(seconds: 15) { completion in
      completion(.success(42))
      completion(.failure(RemoteError.posix(EIO)))
    } == 42)
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await call.run(seconds: 15) { $0(.failure(RemoteError.posix(EACCES))) }
  }
}

@MainActor @Test func cameraCallExpiresWithoutStartingAndRejectsLateSuccess() async throws {
  let clock = ManualTestClock()
  let call = CameraCall<Int>(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await call.run(until: clock.now) { _ in Issue.record("过期请求不应启动") }
  }
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await call.run(seconds: 15) { completion in
      clock.advance(by: .seconds(16))
      completion(.success(1))
    }
  }
}

@MainActor @Test func cameraCallTimeoutAndCancellationFinishPendingRequest() async {
  for cancel in [false, true] {
    let clock = ManualTestClock()
    let call = CameraCall<Int>(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
    let task = Task { try await call.run(seconds: 15) { _ in } }
    await clock.waitForSleepRequests(1)
    if cancel { task.cancel() } else { clock.advance(by: .seconds(15)) }
    do {
      _ = try await task.value
      Issue.record("等待中的请求应终止")
    } catch {
      if cancel {
        #expect(error is CancellationError)
      } else {
        #expect(error as? RemoteError == .posix(ETIMEDOUT))
      }
    }
  }
}

@Test func cameraIdentityPrefersPortAndRejectsAmbiguousSerial() {
  #expect(
    CameraIdentity.identifier(location: 12, uuid: "uuid", persistent: "persistent") == "usb:12")
  #expect(CameraIdentity.identifier(location: 0, uuid: " \n", persistent: " saved \n") == "saved")
  #expect(CameraIdentity.identifier(location: 0, uuid: " uuid ", persistent: "saved") == "uuid")
  #expect(CameraIdentity.identifier(location: 0, uuid: nil, persistent: nil) == nil)
  let devices = [
    (id: "one", serial: "shared"), (id: "two", serial: "shared"), (id: "three", serial: "unique"),
  ]
  #expect(CameraIdentity.selectedID("one", devices: devices) == "one")
  #expect(CameraIdentity.selectedID("shared", devices: devices) == nil)
  #expect(CameraIdentity.selectedID("unique", devices: devices) == "three")
  #expect(CameraIdentity.selectedID("", devices: devices) == nil)
  #expect(CameraIdentity.selectedID("unknown", devices: devices) == nil)
  #expect(CameraIdentity.isGRIV(" ricoh  gr iv \n"))
  #expect(CameraIdentity.isGRIV("GR IV"))
  #expect(!CameraIdentity.isGRIV("RICOH GR III"))
}
