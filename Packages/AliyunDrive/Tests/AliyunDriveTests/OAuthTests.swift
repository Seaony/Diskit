@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import AliyunDrive

private let oauthConfiguration = AliyunConfiguration(
  clientID: "test-client", clientSecret: "test-secret", redirectURI: "kayoi://oauth/callback")

private typealias OAuthSecrets = TestSecretStore

private actor OAuthHTTP: HTTPTransport {
  var requests: [URLRequest] = []
  var uploads: [URLRequest] = []
  let reply: @Sendable (URLRequest) async throws -> HTTPResponse
  init(_ reply: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
    self.reply = reply
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    uploads.append(request)
    return try await send(request)
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try await reply(request)
  }
}

private func oauthToken(_ access: String = "fresh-access", _ refresh: String = "fresh-refresh")
  -> HTTPResponse
{
  HTTPResponse(
    status: 200,
    body: Data(
      "{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\",\"token_type\":\"Bearer\",\"expires_in\":7200}"
        .utf8))
}
private func oauthRequest(_ path: String = "/test") -> URLRequest {
  URLRequest(url: URL(string: "https://openapi.alipan.com" + path)!)
}
private func oauthStore(
  _ secrets: OAuthSecrets, key: String, expiry: TimeInterval = Date.distantFuture.timeIntervalSince1970
) throws {
  let record = AliyunStoredAuthorization(
    accessToken: "old-access", refreshToken: "old-refresh", expiresAt: expiry,
    configuration: oauthConfiguration)
  try secrets.write(JSONEncoder().encode(record), for: key)
}
private func oauthRecord(_ secrets: OAuthSecrets, key: String) throws -> AliyunStoredAuthorization {
  try JSONDecoder().decode(AliyunStoredAuthorization.self, from: #require(try secrets.read(key)))
}

@Test func oauthConfigurationAndStateAreRequiredBeforeNetwork() async throws {
  let transport = OAuthHTTP { _ in throw URLError(.badServerResponse) }
  let session = AliyunSession(
    secretKey: "missing.oauth", secrets: OAuthSecrets(), configuration: AliyunConfiguration(),
    transport: transport)
  await #expect(throws: AliyunError.missingConfiguration) {
    try await session.authorizationURL(state: "state")
  }
  await #expect(throws: AliyunError.missingConfiguration) {
    try await session.exchange(code: "code")
  }
  #expect(throws: AliyunError.invalidState) { try oauthConfiguration.authorizationURL(state: "") }
  #expect(await transport.requests.isEmpty)
}

@Test func oauthAuthorizationURLHasExactScopesStateAndFolderStyle() throws {
  let state = "state &?=中文"
  let url = try oauthConfiguration.authorizationURL(state: state)
  let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  let values = Dictionary(
    uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  #expect(parts.host == "openapi.alipan.com")
  #expect(parts.path == "/oauth/authorize")
  #expect(values["client_id"] == "test-client")
  #expect(values["redirect_uri"] == "kayoi://oauth/callback")
  #expect(values["scope"] == "user:base,file:all:read,file:all:write")
  #expect(values["response_type"] == "code")
  #expect(values["style"] == "folder")
  #expect(values["state"] == state)
  #expect(!url.absoluteString.contains("test-secret"))
}

@Test func oauthExchangePersistsRotatingTokensAndProtectedCLIConfiguration() async throws {
  let key = "exchange.oauth"
  let secrets = OAuthSecrets()
  let transport = OAuthHTTP { request in
    if request.url?.path == "/oauth/access_token" { return oauthToken() }
    return HTTPResponse(status: 200)
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
  try await session.exchange(code: "one-use-code")
  #expect(try await session.hasToken())
  let saved = try oauthRecord(secrets, key: key)
  #expect(saved.accessToken == "fresh-access" && saved.refreshToken == "fresh-refresh")
  #expect(saved.configuration == oauthConfiguration)
  #expect(saved.expiresAt == 8_200)
  let requests = await transport.requests
  let first = try #require(requests.first)
  let body = try #require(
    JSONSerialization.jsonObject(with: first.httpBody ?? Data()) as? [String: String])
  #expect(first.httpMethod == "POST" && first.timeoutInterval == 30)
  #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(body["grant_type"] == "authorization_code" && body["code"] == "one-use-code")
  #expect(body["client_secret"] == "test-secret")
  var expired = saved
  expired.expiresAt = 0
  try secrets.write(JSONEncoder().encode(expired), for: key)
  let cli = AliyunSession(
    secretKey: key, secrets: secrets, configuration: AliyunConfiguration(), transport: transport)
  _ = try await cli.authorized(oauthRequest())
  let refreshed = await transport.requests.filter { $0.url?.path == "/oauth/access_token" }
  #expect(refreshed.count == 2)
  let refreshBody = try #require(
    JSONSerialization.jsonObject(with: refreshed[1].httpBody ?? Data()) as? [String: String])
  #expect(
    refreshBody["client_id"] == "test-client" && refreshBody["client_secret"] == "test-secret")
  #expect(
    refreshBody["grant_type"] == "refresh_token" && refreshBody["refresh_token"] == "fresh-refresh")
}

@Test func oauthExpiredTokenRefreshIsSharedAcrossConcurrentRequests() async throws {
  let key = "concurrent-refresh.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let started = TestEvent()
  let release = TestEvent()
  let transport = OAuthHTTP { request in
    if request.url?.path == "/oauth/access_token" {
      started.signal()
      try await release.wait()
      return oauthToken()
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
    return HTTPResponse(status: 200)
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { _ = try await session.authorized(oauthRequest()) }
    try await started.wait()
    for _ in 0..<7 {
      let read = AsyncStream<Void>.makeStream()
      secrets.nextRead.withLock { $0 = read.continuation }
      group.addTask { _ = try await session.authorized(oauthRequest()) }
      for await _ in read.stream { break }
    }
    release.signal()
    try await group.waitForAll()
  }
  #expect(await transport.requests.filter { $0.url?.path == "/oauth/access_token" }.count == 1)
  #expect(try oauthRecord(secrets, key: key).refreshToken == "fresh-refresh")
}

@Test func oauthInvalidAccessTokenRefreshesOnlyOnceThenRetriesRequest() async throws {
  for (status, code) in [(401, "AccessTokenExpired"), (400, "AccessTokenInvalid")] {
    let key = UUID().uuidString + ".oauth"
    let secrets = OAuthSecrets()
    try oauthStore(secrets, key: key)
    let transport = OAuthHTTP { request in
      if request.url?.path == "/oauth/access_token" { return oauthToken() }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
        return HTTPResponse(status: status, body: Data("{\"code\":\"\(code)\"}".utf8))
      }
      return HTTPResponse(status: 200)
    }
    let session = AliyunSession(
      secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
    #expect(try await session.authorized(oauthRequest()).status == 200)
    #expect(await transport.requests.count == 3)
    #expect(try oauthRecord(secrets, key: key).accessToken == "fresh-access")
  }
}

@Test(arguments: [false, true])
func oauthPermissionFailurePreservesLoginWithoutInvalidation(_ stream: Bool) async throws {
  let key = UUID().uuidString + ".oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let received = Mutex<[String]>([])
  let observer = NotificationCenter.default.addObserver(
    forName: AliyunSession.loginInvalidatedNotification, object: nil, queue: nil
  ) { notification in
    guard notification.userInfo?["secretKey"] as? String == key else { return }
    received.withLock { $0.append(key) }
    #expect(notification.userInfo?.count == 1)
  }
  defer { NotificationCenter.default.removeObserver(observer) }
  let transport = OAuthHTTP { _ in
    HTTPResponse(status: 403, body: Data(#"{"code":"PermissionDenied"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  for _ in 0..<2 {
    await #expect(throws: RemoteError.posix(EACCES)) {
      if stream {
        _ = try await session.authorizedStream(oauthRequest())
      } else {
        _ = try await session.authorized(oauthRequest())
      }
    }
  }
  #expect(await transport.requests.count == 2)
  #expect(received.withLock { $0.count } == 0)
  #expect(try await session.hasToken())
  #expect(try !oauthRecord(secrets, key: key).invalidated)
}

@Test func oauthRefreshFailureKeepsProtectedRecordButRequiresNewLogin() async throws {
  let key = "refresh-failure.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let transport = OAuthHTTP { _ in
    HTTPResponse(status: 401, body: Data(#"{"code":"RefreshTokenExpired"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  await #expect(throws: AliyunError.loginRequired) { try await session.authorized(oauthRequest()) }
  let stored = try oauthRecord(secrets, key: key)
  #expect(stored.invalidated && stored.configuration == oauthConfiguration)
  #expect(try await !session.hasToken())
}

@Test func oauthSecondUnauthorizedResponseStopsAndNeedsLogin() async throws {
  let key = "repeat-invalid.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let transport = OAuthHTTP { request in
    if request.url?.path == "/oauth/access_token" { return oauthToken() }
    return HTTPResponse(status: 401, body: Data(#"{"code":"AccessTokenInvalid"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  await #expect(throws: AliyunError.loginRequired) { try await session.authorized(oauthRequest()) }
  #expect(await transport.requests.count == 3)
  #expect(try await session.hasToken())
  #expect(try !oauthRecord(secrets, key: key).invalidated)
}

@Test func oauthSignedURLDoesNotReceiveBearerOrTriggerTokenRefresh() async throws {
  let key = "signed.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let transport = OAuthHTTP { request in
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    return HTTPResponse(status: 403, body: Data(#"{"code":"AccessTokenInvalid"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  var request = URLRequest(url: URL(string: "https://download.example.com/file?signature=test")!)
  request.setValue("Bearer should-be-removed", forHTTPHeaderField: "Authorization")
  #expect(try await session.authorized(request).status == 403)
  #expect(await transport.requests.count == 1)
  #expect(try await session.hasToken())
}

@Test func oauthAccountUsesAuthorizedFolderAndExactQuota() async throws {
  let key = "account.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let transport = OAuthHTTP { request in
    #expect(request.httpMethod == "POST")
    if request.url?.path == "/adrive/v1.0/user/getDriveInfo" {
      return HTTPResponse(
        status: 200,
        body: Data(
          #"{"default_drive_id":"drive","user_id":"user","name":"昵称","folder_id":"chosen-folder"}"#
            .utf8))
    }
    return HTTPResponse(
      status: 200,
      body: Data(#"{"personal_space_info":{"total_size":9000000000,"used_size":3456789012}}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  let account = try await session.account()
  #expect(account.driveID == "drive" && account.rootFolderID == "chosen-folder")
  #expect(account.userID == "user" && account.nickname == "昵称")
  #expect(account.total == 9_000_000_000 && account.used == 3_456_789_012)
}

private final class OAuthBatchGate: Sendable {
  private let state = Mutex((entered: 0, queued: 0))
  private let release = TestEvent()
  func observeQueue(_ count: Int) {
    let ready = state.withLock { value in
      value.queued = count
      return value.entered + value.queued >= 12 || value.entered > 4
    }
    if ready { release.signal() }
  }
  func enter() async throws {
    let ready = state.withLock { value in
      value.entered += 1
      return value.entered + value.queued >= 12 || value.entered > 4
    }
    if ready { release.signal() }
    try await release.wait()
  }
}

private actor OAuthBurstHTTP: HTTPTransport {
  let gate = OAuthBatchGate()
  var active = 0, maximum = 0, calls = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    active += 1
    maximum = max(maximum, active)
    calls += 1
    defer { active -= 1 }
    try await gate.enter()
    return HTTPResponse(status: 200)
  }
}

@Test func oauthRequestConcurrencyNeverExceedsFour() async throws {
  let key = "limit.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let transport = OAuthBurstHTTP()
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  let limit = HTTPConcurrencyLimit.shared(for: "aliyun:" + secrets.refreshLockLocation(for: "limit.oauth").path)
  await limit.observeQueue { transport.gate.observeQueue($0) }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<12 { group.addTask { _ = try await session.authorized(oauthRequest()) } }
    try await group.waitForAll()
  }
  #expect(await transport.maximum == 4)
  #expect(await transport.calls == 12)
}

private actor OAuthStreamHTTP: HTTPTransport {
  var count = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse { HTTPResponse(status: 200) }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    count += 1
    return HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data([1, 2, 3]))
        continuation.finish()
      })
  }
}

@Test func oauthStreamingHoldsConcurrencySlotUntilBodyEnds() async throws {
  let transport = OAuthStreamHTTP()
  let secrets = OAuthSecrets()
  let session = AliyunSession(
    secretKey: "streams.oauth", secrets: secrets, configuration: AliyunConfiguration(),
    transport: transport)
  let request = URLRequest(url: URL(string: "https://download.example.com/file")!)
  var responses: [HTTPStreamResponse] = []
  for _ in 0..<4 { responses.append(try await session.authorizedStream(request)) }
  let queued = TestEvent()
  let limit = HTTPConcurrencyLimit.shared(for: "aliyun:" + secrets.refreshLockLocation(for: "streams.oauth").path)
  await limit.observeQueue { if $0 == 1 { queued.signal() } }
  let fifth = Task { try await session.authorizedStream(request) }
  try await queued.wait()
  #expect(await transport.count == 4)
  for try await _ in responses[0].body {}
  let extra = try await fifth.value
  #expect(await transport.count == 5)
  for response in responses.dropFirst() { for try await _ in response.body {} }
  for try await _ in extra.body {}
}

@Test func oauthRateLimitUsesMillisecondHeaderAndStopsAfterThreeAttempts() async throws {
  let millis = HTTPResponse(status: 429, headers: ["X-Retry-After": "2500", "Retry-After": "9"])
  #expect(AliyunSession.retryDelay(millis, attempt: 0) == 2.5)
  #expect(
    AliyunSession.retryDelay(HTTPResponse(status: 429, headers: ["Retry-After": "3"]), attempt: 0)
      == 3)
  let key = "limited.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key)
  let transport = OAuthHTTP { _ in HTTPResponse(status: 429, headers: ["x-retry-after": "0"]) }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  await #expect(throws: AliyunError.rateLimited) { try await session.authorized(oauthRequest()) }
  #expect(await transport.requests.count == 3)
}

@Test(arguments: [0, 429, 500, 401])
func oauthTransientRefreshFailurePreservesLogin(_ status: Int) async throws {
  let key = "transient-\(status).oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let original = try secrets.read(key)
  let transport = OAuthHTTP { request in
    guard request.url?.path == "/oauth/access_token" else { throw RemoteError.protocolError }
    if status == 0 { throw URLError(.notConnectedToInternet) }
    return HTTPResponse(status: status, headers: ["Retry-After": "31"], body: Data("{}".utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  do {
    _ = try await session.authorized(oauthRequest())
    Issue.record("刷新失败不应成功")
  } catch { #expect((error as? AliyunError) != .loginRequired) }
  #expect(try secrets.read(key) == original)
  #expect(try await session.hasToken())
}

@Test func oauthExplicitInvalidGrantRequiresNewLogin() async throws {
  let key = "invalid-grant.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let transport = OAuthHTTP { request in
    guard request.url?.path == "/oauth/access_token" else { throw RemoteError.protocolError }
    return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  await #expect(throws: AliyunError.loginRequired) {
    _ = try await session.authorized(oauthRequest())
  }
  #expect(try oauthRecord(secrets, key: key).invalidated)
}

@Test func oauthRefreshRecoversAfterTemporaryFailureWithoutLogin() async throws {
  let key = "refresh-recovery.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let attempts = Mutex(0)
  let transport = OAuthHTTP { request in
    if request.url?.path == "/test" { return HTTPResponse(status: 200) }
    guard request.url?.path == "/oauth/access_token" else { throw RemoteError.protocolError }
    let number = attempts.withLock {
      $0 += 1
      return $0
    }
    return number == 1 ? HTTPResponse(status: 500) : oauthToken()
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  await #expect(throws: AliyunError.authorizationFailed(500)) {
    _ = try await session.authorized(oauthRequest())
  }
  #expect(try await session.authorized(oauthRequest()).status == 200)
  #expect(try oauthRecord(secrets, key: key).refreshToken == "fresh-refresh")
  #expect(attempts.withLock { $0 } == 2)
}

@Test(arguments: [false, true])
func aliyunRetriesPersistingRotatedTokenBeforeRefreshingAgain(newSession: Bool) async throws {
  let key = "persist-retry.oauth"
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: key, expiry: 0)
  let refreshes = Mutex(0)
  let transport = OAuthHTTP { request in
    if request.url?.path == "/test" { return HTTPResponse(status: 200) }
    guard request.url?.path == "/oauth/access_token" else { throw RemoteError.protocolError }
    let count = refreshes.withLock {
      $0 += 1
      return $0
    }
    return count == 1
      ? oauthToken() : HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
  }
  let session = AliyunSession(
    secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
  secrets.failWrites.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { _ = try await session.authorized(oauthRequest()) }
  secrets.failWrites.withLock { $0 = false }
  let retrySession =
    newSession
    ? AliyunSession(
      secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport)
    : session
  #expect(try await retrySession.authorized(oauthRequest()).status == 200)
  #expect(try oauthRecord(secrets, key: key).refreshToken == "fresh-refresh")
  #expect(refreshes.withLock { $0 } == 1)
}

@Test(arguments: [false, true])
func aliyunSeparateSessionsShareRefresh(separateSessions: Bool) async throws {
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: "concurrent", expiry: 0)
  let started = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let count = Mutex(0)
  let http = OAuthHTTP { request in
    guard request.url?.path == "/oauth/access_token" else { return HTTPResponse(status: 200) }
    let number = count.withLock {
      $0 += 1
      return $0
    }
    if number == 1 {
      started.continuation.yield(())
      started.continuation.finish()
      for await _ in release.stream { break }
    }
    return oauthToken()
  }
  let first = AliyunSession(
    secretKey: "concurrent", secrets: secrets, configuration: oauthConfiguration, transport: http)
  let second =
    separateSessions
    ? AliyunSession(
      secretKey: "concurrent", secrets: secrets, configuration: oauthConfiguration, transport: http)
    : first
  let firstTask = Task { try await first.authorized(oauthRequest()) }
  for await _ in started.stream { break }
  let read = AsyncStream<Void>.makeStream()
  secrets.nextRead.withLock { $0 = read.continuation }
  let secondTask = Task { try await second.authorized(oauthRequest()) }
  for await _ in read.stream { break }
  release.continuation.yield(())
  release.continuation.finish()
  #expect(try await firstTask.value.status == 200)
  #expect(try await secondTask.value.status == 200)
  #expect(count.withLock { $0 } == 1)
}

@Test func aliyunUploadRetryKeepsTransferRouting() async throws {
  let calls = Mutex(0)
  let http = OAuthHTTP { _ in
    let number = calls.withLock {
      $0 += 1
      return $0
    }
    return HTTPResponse(status: number == 1 ? 429 : 200, headers: ["Retry-After": "0"])
  }
  let session = AliyunSession(
    secretKey: "local", secrets: MemorySecretStore(), configuration: oauthConfiguration,
    transport: http)
  var request = URLRequest(url: URL(string: "https://upload.example.invalid/file")!)
  request.httpMethod = "PUT"
  request.httpBody = Data()
  #expect(try await session.authorized(request, upload: true).status == 200)
  #expect(await http.uploads.count == 2)
  _ = try await session.authorized(request)
  #expect(await http.requests.count == 3)
  #expect(await http.uploads.count == 2)
}

@Test func oauthDiscardedUnreadStreamReleasesConcurrencySlot() async throws {
  let transport = OAuthStreamHTTP()
  let secrets = OAuthSecrets()
  let session = AliyunSession(
    secretKey: "discard.oauth", secrets: secrets, configuration: AliyunConfiguration(),
    transport: transport)
  let request = URLRequest(url: URL(string: "https://download.example.invalid/file")!)
  var responses: [HTTPStreamResponse] = []
  for _ in 0..<4 { responses.append(try await session.authorizedStream(request)) }
  let queued = TestEvent()
  let limit = HTTPConcurrencyLimit.shared(for: "aliyun:" + secrets.refreshLockLocation(for: "discard.oauth").path)
  await limit.observeQueue { if $0 == 1 { queued.signal() } }
  let fifth = Task { try await session.authorizedStream(request) }
  defer { fifth.cancel() }
  try await queued.wait()
  #expect(await transport.count == 4)
  responses.removeLast()
  let last = try await fifth.value
  #expect(await transport.count == 5)
  for response in responses { for try await _ in response.body {} }
  for try await _ in last.body {}
}

@Test func aliyunSeparateSessionsShareRequestAllowance() async throws {
  let secrets = OAuthSecrets()
  try oauthStore(secrets, key: "shared-limit")
  let transport = OAuthBurstHTTP()
  let first = AliyunSession(
    secretKey: "shared-limit", secrets: secrets, configuration: oauthConfiguration,
    transport: transport)
  let second = AliyunSession(
    secretKey: "shared-limit", secrets: secrets, configuration: oauthConfiguration,
    transport: transport)
  let limit = HTTPConcurrencyLimit.shared(for: "aliyun:" + secrets.refreshLockLocation(for: "shared-limit").path)
  await limit.observeQueue { transport.gate.observeQueue($0) }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<12 {
      group.addTask {
        _ = try await (index.isMultiple(of: 2) ? first : second).authorized(oauthRequest())
      }
    }
    try await group.waitForAll()
  }
  #expect(await transport.maximum <= 4)
  #expect(await transport.maximum > 1)
  #expect(await transport.calls == 12)
}

@Test(arguments: [false, true])
func aliyunCancelledOrExpiredWaiterLeavesSharedRefreshRunning(cancel: Bool) async throws {
  let secrets = OAuthSecrets()
  let key = "cancel-shared"
  try oauthStore(secrets, key: key, expiry: 0)
  let entered = TestEvent()
  let release = TestEvent()
  let clock = ManualTestClock()
  let count = Mutex(0)
  defer { release.signal() }
  let transport = OAuthHTTP { request in
    if request.url?.path == "/test" { return HTTPResponse(status: 200) }
    guard request.url?.path == "/oauth/access_token" else { throw RemoteError.protocolError }
    count.withLock { $0 += 1 }
    entered.signal()
    try await release.wait()
    #expect(!Task.isCancelled)
    return oauthToken()
  }
  let session = AliyunSession(secretKey: key, secrets: secrets, configuration: oauthConfiguration, transport: transport, now: { Date() }, makeDeadline: {
    HTTPProgressDeadline(interval: .seconds(30), clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0, tolerance: nil) }))
  })
  let caller = Task { try await session.authorized(oauthRequest()) }
  try await entered.wait()
  if cancel { caller.cancel() } else { await clock.waitForSleepRequests(1); clock.advance(by: .seconds(30)) }
  do { _ = try await caller.value; Issue.record("等待者应及时退出") }
  catch {
    if cancel { #expect(error is CancellationError) }
    else { #expect((error as? URLError)?.code == .timedOut) }
  }
  #expect(!release.isSignaled)
  let survivor = Task { try await session.authorized(oauthRequest()) }
  release.signal()
  #expect(try await survivor.value.status == 200)
  #expect(count.withLock { $0 } == 1)
  #expect(try oauthRecord(secrets, key: key).refreshToken == "fresh-refresh")
}
