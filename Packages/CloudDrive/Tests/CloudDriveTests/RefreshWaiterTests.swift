import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CloudDrive
@testable import Core

private let waiterConfiguration = OAuthConfiguration(
  clientID: "local", clientSecret: "",
  authorizationURL: URL(string: "https://example.invalid/auth")!,
  tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://test", scopes: [])

private actor RefreshWaiterProbe: HTTPTransport {
  let entered = TestEvent()
  let release = TestEvent()
  var refreshes = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path == "/token" {
      refreshes += 1
      entered.signal()
      try await release.wait()
      #expect(!Task.isCancelled)
      return HTTPResponse(
        status: 200,
        body: Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8))
    }
    return HTTPResponse(status: 200)
  }
}

private final class WaiterSecretStore: SecretStore {
  let base = MemorySecretStore()
  let failWrites = Mutex(false)
  let failedWrite = TestEvent()
  func refreshLockLocation(for key: String) -> URL { base.refreshLockLocation(for: key) }
  func read(_ key: String) throws -> Data? { try base.read(key) }
  func write(_ data: Data, for key: String) throws {
    if failWrites.withLock({ $0 }) {
      failedWrite.signal()
      throw CocoaError(.fileWriteNoPermission)
    }
    try base.write(data, for: key)
  }
  func delete(_ key: String) throws { try base.delete(key) }
}

private func waiterSession(
  _ secrets: any SecretStore, _ probe: RefreshWaiterProbe, clock: ManualTestClock? = nil
) throws -> OAuthSession {
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)),
    for: "account")
  if let clock {
    return OAuthSession(
      configuration: waiterConfiguration, secretKey: "account", secrets: secrets, transport: probe,
      makeDeadline: {
        HTTPProgressDeadline(
          interval: .seconds(30),
          clock: DeadlineClock(
            now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0, tolerance: nil) }))
      })
  }
  return OAuthSession(
    configuration: waiterConfiguration, secretKey: "account", secrets: secrets, transport: probe)
}

@Test func cancelledOAuthWaiterKeepsOneSharedRefreshForOtherCallers() async throws {
  let secrets = MemorySecretStore()
  let probe = RefreshWaiterProbe()
  defer { probe.release.signal() }
  let session = try waiterSession(secrets, probe)
  let first = Task { try await session.accessToken() }
  try await probe.entered.wait()
  let second = Task { try await session.accessToken() }
  first.cancel()
  await #expect(throws: CancellationError.self) { _ = try await first.value }
  #expect(!probe.release.isSignaled)
  #expect(await probe.refreshes == 1)
  probe.release.signal()
  #expect(try await second.value == "new")
  #expect(await probe.refreshes == 1)
  #expect(try await session.tokenForTesting()?.refreshToken == "rotated")
}

@Test(arguments: ["token", "refresh", "request", "stream", "uploadToken"])
func OAuthCallerDeadlineDoesNotWaitForSharedRefreshToFinish(entry: String) async throws {
  let secrets = MemorySecretStore()
  let probe = RefreshWaiterProbe()
  let clock = ManualTestClock()
  defer { probe.release.signal() }
  let session = try waiterSession(secrets, probe, clock: clock)
  let caller = Task<Void, Error> {
    let request = URLRequest(url: URL(string: "https://example.invalid/files")!)
    switch entry {
    case "token": _ = try await session.accessToken()
    case "refresh": _ = try await session.refreshNow()
    case "stream": _ = try await session.authorizedStream(request)
    default: _ = try await session.authorized(request, upload: entry == "uploadToken")
    }
  }
  try await probe.entered.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  do {
    try await caller.value
    Issue.record("调用者应在总截止时间退出")
  } catch let error as URLError { #expect(error.code == .timedOut) }
  #expect(!probe.release.isSignaled)
  #expect(await probe.refreshes == 1)
  let survivor = Task { try await session.accessToken() }
  probe.release.signal()
  #expect(try await survivor.value == "new")
  #expect(await probe.refreshes == 1)
}

@Test func cancelledOAuthWaiterDoesNotLoseRotatedTokenAfterStorageFailure() async throws {
  let secrets = WaiterSecretStore()
  let probe = RefreshWaiterProbe()
  defer { probe.release.signal() }
  let session = try waiterSession(secrets, probe)
  let caller = Task { try await session.accessToken() }
  try await probe.entered.wait()
  caller.cancel()
  await #expect(throws: CancellationError.self) { _ = try await caller.value }
  secrets.failWrites.withLock { $0 = true }
  probe.release.signal()
  try await secrets.failedWrite.wait()
  let oldData = try #require(try secrets.base.read("account"))
  let old = try JSONDecoder().decode(OAuthToken.self, from: oldData)
  #expect(old.refreshToken == "refresh")
  secrets.failWrites.withLock { $0 = false }
  #expect(try await session.accessToken() == "new")
  #expect(try await session.tokenForTesting()?.refreshToken == "rotated")
  #expect(await probe.refreshes == 1)
}
