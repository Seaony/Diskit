import CoreTestSupport
import Foundation
import NetFS
import Testing

@testable import Core

@Test(arguments: [false, true])
@MainActor func lateSuccessfulMountIsEjectedAfterAbandonment(cancelled: Bool) async throws {
  var ejected: [URL] = []
  let request = MountRequest(unmountLate: { ejected.append($0) })
  do {
    _ = try await request.waitForResult {
      request.finish(.failure(cancelled ? CancellationError() : ConnectionError.timeout))
    }
    Issue.record("已放弃的挂载不应成功")
  } catch {
    if cancelled {
      #expect(error is CancellationError)
    } else {
      #expect(error as? ConnectionError == .timeout)
    }
  }
  await request.received(status: 0, paths: ["/Volumes/late-one", "/Volumes/late-two"])
  #expect(ejected.map(\.path) == ["/Volumes/late-one", "/Volumes/late-two"])
}

@Test @MainActor func deliveredMountIsNotEjectedByLaterFailure() async throws {
  var ejected: [URL] = []
  let request = MountRequest(unmountLate: { ejected.append($0) })
  let mounted = try await request.waitForResult {
    request.finish(.success(URL(filePath: "/Volumes/accepted")))
  }
  #expect(mounted.path == "/Volumes/accepted")
  request.finish(.failure(ConnectionError.timeout))
  await request.received(status: Int32(EIO), paths: [])
  #expect(ejected.isEmpty)
}

@Test @MainActor func lateMountCleanupFailureDoesNotSkipOtherMounts() async throws {
  var attempted: [String] = []
  var failed: [String] = []
  let request = MountRequest(
    unmountLate: { url in
      attempted.append(url.path)
      if url.lastPathComponent == "busy" { throw ConnectionError.busy }
    },
    cleanupFailed: { url, error in
      failed.append(url.path)
      #expect(error as? ConnectionError == .busy)
    })
  await #expect(throws: ConnectionError.timeout) {
    _ = try await request.waitForResult { request.finish(.failure(ConnectionError.timeout)) }
  }
  await request.received(status: 0, paths: ["/Volumes/busy", "/Volumes/other"])
  #expect(attempted == ["/Volumes/busy", "/Volumes/other"])
  #expect(failed == ["/Volumes/busy"])
}

@MainActor private final class FixtureMountCall: MountCalling {
  var status: Int32 = 0
  var completion: (@Sendable (Int32, [String]) -> Void)?
  var options: NSDictionary?
  var mountOptions: NSDictionary?
  var cancelled = 0
  var completions = 0
  func start(
    url: URL, mountPoint: URL?, user: String, password: String,
    options: NSMutableDictionary, mountOptions: NSMutableDictionary?,
    completion: @escaping @Sendable (Int32, [String]) -> Void
  ) -> Int32 {
    self.options = options
    self.mountOptions = mountOptions
    self.completion = completion
    return status
  }
  func cancel() { cancelled += 1 }
  func finished() { completions += 1 }
}

@MainActor @Test func mountRequestBuildsOptionsAndDeliversNativeResult() async throws {
  for guest in [false, true] {
    let native = FixtureMountCall()
    let clock = ManualTestClock()
    let request = MountRequest(native: native, clock: clock.deadlineClock)
    let task = Task {
      try await request.run(
        url: URL(string: "smb://fixture.invalid/share")!, user: "fixture", password: "fixture",
        guest: guest, mountPoint: guest ? URL(filePath: "/fixture") : nil)
    }
    await clock.waitForSleepRequests(1)
    #expect((native.options?[kNetFSUseGuestKey as String] as? Bool) == (guest ? true : nil))
    #expect((native.options?[kNetFSUseAuthenticationInfoKey as String] as? Bool) == false)
    #expect((native.options?[kNetFSForceNewSessionKey as String] as? Bool) == true)
    #expect((native.mountOptions != nil) == guest)
    native.completion?(0, ["/fixture"])
    #expect(try await task.value.path == "/fixture")
    #expect(native.cancelled == 0)
    #expect(native.completions == 1)
  }
}

@MainActor @Test func mountRequestNativeFailureTimeoutAndCancellation() async {
  let immediate = FixtureMountCall()
  immediate.status = EACCES
  await #expect(throws: ConnectionError.status(EACCES)) {
    try await MountRequest(native: immediate).run(
      url: URL(string: "smb://fixture.invalid/share")!, user: "", password: "")
  }
  for cancel in [false, true] {
    let native = FixtureMountCall()
    let clock = ManualTestClock()
    let request = MountRequest(native: native, clock: clock.deadlineClock)
    let task = Task {
      try await request.run(
        url: URL(string: "smb://fixture.invalid/share")!, user: "", password: "")
    }
    await clock.waitForSleepRequests(1)
    if cancel { task.cancel() } else { clock.advance(by: .seconds(RemoteTimeout.deviceRequest)) }
    do {
      _ = try await task.value
      Issue.record("等待中的挂载应终止")
    } catch {
      if cancel {
        #expect(error is CancellationError)
      } else {
        #expect(error as? ConnectionError == .timeout)
      }
    }
    #expect(native.cancelled == 1)
  }
}

@MainActor @Test func mountRequestRejectsEmptySuccessfulResponse() async {
  let native = FixtureMountCall()
  let clock = ManualTestClock()
  let request = MountRequest(native: native, clock: clock.deadlineClock)
  let task = Task {
    try await request.run(url: URL(string: "smb://fixture.invalid/share")!, user: "", password: "")
  }
  await clock.waitForSleepRequests(1)
  native.completion?(0, [])
  await #expect(throws: ConnectionError.status(EIO)) { try await task.value }
}
