import Foundation
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
