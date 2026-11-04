import Core
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class MemorySecrets: SecretStore, Sendable {
  let failWrites = Mutex(false)
  let values = Mutex<[String: Data]>([:])

  func read(_ key: String) throws -> Data? {
    values.withLock { $0[key] }
  }

  func write(_ data: Data, for key: String) throws {
    if failWrites.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    values.withLock { $0[key] = data }
  }

  func delete(_ key: String) throws {
    _ = values.withLock { $0.removeValue(forKey: key) }
  }
}

private final class FakeTransport: HTTPTransport, Sendable {
  let responses = Mutex<[HTTPResponse]>([])
  let requests = Mutex<[URLRequest]>([])
  let streamResponse: HTTPResponse

  init(_ responses: [HTTPResponse] = [], streamResponse: HTTPResponse? = nil) {
    self.responses.withLock { $0 = responses }
    self.streamResponse = streamResponse ?? HTTPResponse(status: 200)
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return responses.withLock {
      guard !$0.isEmpty else { return HTTPResponse(status: 500) }
      return $0.removeFirst()
    }
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.withLock { $0.append(request) }
    return HTTPStreamResponse(
      response: streamResponse,
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data("range".utf8))
        continuation.finish()
      })
  }
}

private let configuration = OAuthConfiguration(
  clientID: "client",
  clientSecret: "secret",
  authorizationURL: URL(string: "https://example.com/authorize")!,
  tokenURL: URL(string: "https://example.com/token")!,
  redirectURI: "kayoi://oauth/test",
  scopes: ["files.read", "files.write"],
  additionalAuthorizationItems: ["prompt": "select_account"])

private func tokenResponse(
  access: String, refresh: String? = "refresh", expiresIn: Int = 3_600
) -> HTTPResponse {
  var object: [String: Any] = ["access_token": access, "expires_in": expiresIn]
  object["refresh_token"] = refresh
  return HTTPResponse(
    status: 200, body: try! JSONSerialization.data(withJSONObject: object))
}

@Test func buildsAuthorizationURLAndExchangesCode() async throws {
  let transport = FakeTransport([tokenResponse(access: "access")])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: MemorySecrets(), transport: transport
  )

  let authorization = try await session.authorizationURL(state: "state-token")
  let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems
  #expect(query?.first { $0.name == "client_id" }?.value == "client")
  #expect(query?.first { $0.name == "state" }?.value == "state-token")
  #expect(query?.first { $0.name == "scope" }?.value == "files.read files.write")
  #expect(query?.first { $0.name == "prompt" }?.value == "select_account")

  let token = try await session.exchange(code: "code")
  #expect(token.accessToken == "access")
  #expect(token.refreshToken == "refresh")
  let request = try #require(transport.requests.withLock { $0.first })
  let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
  #expect(body.contains("grant_type=authorization_code"))
  #expect(body.contains("code=code"))
}

@Test func pkceChallengeMatchesTheVerifierSentWithTheCode() async throws {
  let transport = FakeTransport([tokenResponse(access: "access")])
  let pkceConfiguration = OAuthConfiguration(
    clientID: "public-client", clientSecret: "",
    authorizationURL: URL(string: "https://example.com/authorize")!,
    tokenURL: URL(string: "https://example.com/token")!,
    redirectURI: "kayoi://oauth/test", scopes: [], usesPKCE: true)
  let session = OAuthSession(
    configuration: pkceConfiguration, secretKey: "oauth", secrets: MemorySecrets(),
    transport: transport)

  let authorization = try await session.authorizationURL(state: "state")
  let challenge = try #require(
    URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "code_challenge" })?.value)
  #expect(
    URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "code_challenge_method" })?.value == "S256")

  _ = try await session.exchange(code: "code")
  let request = try #require(transport.requests.withLock { $0.first })
  let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
  let verifier = try #require(
    URLComponents(string: "https://example.invalid/?\(body)")?.queryItems?
      .first(where: { $0.name == "code_verifier" })?.value)
  let digest = SHA256.hash(data: Data(verifier.utf8))
  let expected = Data(digest).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  #expect(challenge == expected)
}

@Test func unauthorizedResponseRefreshesAndRetriesOnlyOnce() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: "refresh",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([
    HTTPResponse(status: 401),
    tokenResponse(access: "new"),
    HTTPResponse(status: 200, body: Data("ok".utf8)),
  ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)

  let response = try await session.authorized(
    URLRequest(url: URL(string: "https://example.com/files")!))
  #expect(response.status == 200)
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 3)
  #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old")
  #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new")
}

@Test func missingRefreshTokenInvalidatesLogin() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: nil,
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([HTTPResponse(status: 401)])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)

  await #expect(throws: OAuthDriveError.loginRequired) {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://example.com/files")!))
  }
  #expect(try await session.hasToken() == false)
}

@Test func refreshUsesItsOwnEndpoint() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: "refresh",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([
    HTTPResponse(status: 401),
    tokenResponse(access: "new"),
    HTTPResponse(status: 200),
  ])
  let refreshURL = URL(string: "https://example.com/refresh")!
  let refreshConfiguration = OAuthConfiguration(
    clientID: "client", clientSecret: "secret",
    authorizationURL: URL(string: "https://example.com/authorize")!,
    tokenURL: URL(string: "https://example.com/token")!,
    refreshTokenURL: refreshURL,
    redirectURI: "kayoi://oauth/test", scopes: [])
  let session = OAuthSession(
    configuration: refreshConfiguration, secretKey: "oauth", secrets: secrets, transport: transport)

  _ = try await session.authorized(
    URLRequest(url: URL(string: "https://example.com/files")!))
  #expect(transport.requests.withLock { $0[1].url } == refreshURL)
}

@Test func temporaryRefreshFailureKeepsExistingToken() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: "refresh",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([
    HTTPResponse(status: 401),
    HTTPResponse(status: 400, body: Data(#"{"error":"server_error"}"#.utf8)),
  ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)

  await #expect(throws: OAuthDriveError.temporarilyUnavailable) {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://example.com/files")!))
  }
  #expect(try await session.hasToken())
}

@Test func rateLimitedRequestRetriesAfterHeaderDelay() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "access", refreshToken: "refresh",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([
    HTTPResponse(status: 429, headers: ["Retry-After": "0"]),
    HTTPResponse(status: 200, body: Data("ok".utf8)),
  ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  let response = try await session.authorized(
    URLRequest(url: URL(string: "https://example.com/files")!))
  #expect(response.status == 200)
  #expect(transport.requests.withLock { $0.count } == 2)
}

@Test func drive115RefreshTokenErrorInvalidatesLogin() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: "bad",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let transport = FakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":0,"code":40140114,"data":{},"message":"refresh_token 格式错误","errno":40140114}"#
          .utf8))
  ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)

  await #expect(throws: OAuthDriveError.loginRequired) {
    _ = try await session.refreshNow()
  }
  #expect(try await session.hasToken() == false)
}

@Test func drive115RefreshRateLimitKeepsLoginAndUsesRetryHeader() async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "old", refreshToken: "throttled",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  let rateLimit = HTTPResponse(
    status: 200,
    headers: ["Retry-After": "0"],
    body: Data(
      #"{"state":0,"code":40140117,"message":"refresh frequently"}"#.utf8))
  let transport = FakeTransport([rateLimit, rateLimit, rateLimit])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)

  await #expect(throws: OAuthDriveError.temporarilyUnavailable) {
    _ = try await session.refreshNow()
  }
  #expect(try await session.hasToken())
  #expect(transport.requests.withLock { $0.count } == 3)
}

private struct RefreshFailureHTTP: HTTPTransport {
  let status: Int
  let explicitRejection: Bool
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.absoluteString == "https://example.com/token" else {
      throw RemoteError.protocolError
    }
    if status == 0 { throw URLError(.notConnectedToInternet) }
    return HTTPResponse(
      status: status, headers: ["Retry-After": "0"],
      body: Data((explicitRejection ? #"{"error":"invalid_grant"}"# : "{}").utf8))
  }
}

@Test(arguments: [0, 429, 500, 401])
func commonOAuthTransientRefreshPreservesLogin(_ status: Int) async throws {
  let secrets = MemorySecrets()
  let token = OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)
  let original = try JSONEncoder().encode(token)
  try secrets.write(original, for: "oauth")
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets,
    transport: RefreshFailureHTTP(status: status, explicitRejection: status == 500))
  do {
    _ = try await session.refreshNow()
    Issue.record("刷新失败不应成功")
  } catch { #expect((error as? OAuthDriveError) != .loginRequired) }
  #expect(try secrets.read("oauth") == original)
  #expect(try await session.hasToken())
}

@Test(arguments: [200, 400])
func commonOAuthExplicitInvalidGrantInvalidatesLogin(_ status: Int) async throws {
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)),
    for: "oauth")
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets,
    transport: RefreshFailureHTTP(status: status, explicitRejection: true))
  await #expect(throws: OAuthDriveError.loginRequired) { _ = try await session.refreshNow() }
  #expect(try await !session.hasToken())
}

@Test func commonOAuthRefreshRecoversAfterServerFailure() async throws {
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)),
    for: "oauth")
  let transport = FakeTransport([HTTPResponse(status: 500), tokenResponse(access: "recovered")])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  await #expect(throws: OAuthDriveError.temporarilyUnavailable) {
    _ = try await session.refreshNow()
  }
  #expect(try await session.refreshNow() == "recovered")
  #expect(try await session.hasToken())
}

@Test(arguments: [false, true])
func commonOAuthSecondResourceRejectionPreservesNewToken(_ stream: Bool) async throws {
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture)),
    for: "oauth")
  let transport =
    stream
    ? FakeTransport(
      [tokenResponse(access: "new", refresh: "rotated")], streamResponse: HTTPResponse(status: 401))
    : FakeTransport([
      HTTPResponse(status: 401), tokenResponse(access: "new", refresh: "rotated"),
      HTTPResponse(status: 401),
    ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  let request = URLRequest(url: URL(string: "https://example.com/files")!)
  if stream {
    #expect(try await session.authorizedStream(request).response.status == 401)
  } else {
    #expect(try await session.authorized(request).status == 401)
  }
  #expect(try await session.hasToken())
  let saved = try JSONDecoder().decode(OAuthToken.self, from: #require(try secrets.read("oauth")))
  #expect(saved.refreshToken == "rotated")
}

private actor DelayedUnauthorizedHTTP: HTTPTransport {
  private var rejected: [CheckedContinuation<HTTPResponse, Never>] = []
  private(set) var refreshes = 0
  private(set) var oldRequests = 0

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.absoluteString == "https://example.com/token" {
      refreshes += 1
      return tokenResponse(access: "new", refresh: "rotated")
    }
    guard request.url?.absoluteString == "https://example.com/files" else {
      throw RemoteError.protocolError
    }
    if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
      oldRequests += 1
      return await withCheckedContinuation { continuation in
        rejected.append(continuation)
        if oldRequests == 10 { rejected.removeFirst().resume(returning: HTTPResponse(status: 401)) }
      }
    }
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer new" else {
      throw RemoteError.protocolError
    }
    let waiting = rejected
    rejected.removeAll()
    for continuation in waiting { continuation.resume(returning: HTTPResponse(status: 401)) }
    return HTTPResponse(status: 200)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    HTTPStreamResponse(response: try await send(request), body: AsyncThrowingStream { $0.finish() })
  }
}

@Test(arguments: [false, true], [false, true])
func tenDelayedUnauthorizedRequestsShareOneRefresh(_ stream: Bool, separateSessions: Bool)
  async throws
{
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture)),
    for: "oauth")
  let transport = DelayedUnauthorizedHTTP()
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  try await withThrowingTaskGroup(of: Int.self) { group in
    for _ in 0..<10 {
      let requestSession =
        separateSessions
        ? OAuthSession(
          configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
        : session
      group.addTask {
        let request = URLRequest(url: URL(string: "https://example.com/files")!)
        if stream { return try await requestSession.authorizedStream(request).response.status }
        return try await requestSession.authorized(request).status
      }
    }
    for try await status in group { #expect(status == 200) }
  }
  #expect(await transport.oldRequests == 10)
  #expect(await transport.refreshes == 1)
}

@Test(arguments: [false, true])
func commonOAuthRetriesPersistingRotatedTokenBeforeRefreshingAgain(newSession: Bool) async throws {
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)),
    for: "oauth")
  let transport = FakeTransport([
    tokenResponse(access: "new", refresh: "rotated"),
    HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)),
  ])
  let session = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  secrets.failWrites.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { _ = try await session.accessToken() }
  secrets.failWrites.withLock { $0 = false }
  let retrySession =
    newSession
    ? OAuthSession(
      configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
    : session
  #expect(try await retrySession.accessToken() == "new")
  let saved = try JSONDecoder().decode(OAuthToken.self, from: #require(try secrets.read("oauth")))
  #expect(saved.refreshToken == "rotated")
  #expect(transport.requests.withLock { $0.count } == 1)
}

@Test func commonOAuthObservesCredentialsChangedByAnotherSession() async throws {
  let secrets = MemorySecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "old", refreshToken: "old-refresh", expiresAt: Date().addingTimeInterval(3600))
    ),
    for: "oauth")
  let transport = FakeTransport([tokenResponse(access: "fresh", refresh: "rotated")])
  let first = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  let second = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  #expect(try await first.accessToken() == "old")
  _ = try await second.refreshNow()
  #expect(try await first.accessToken() == "fresh")
  #expect(try await first.tokenForTesting()?.refreshToken == "rotated")
  await second.invalidate()
  #expect(try await !first.hasToken())
  await #expect(throws: OAuthDriveError.loginRequired) { _ = try await first.accessToken() }
}

private actor HeldRefreshHTTP: HTTPTransport {
  private var pending: CheckedContinuation<HTTPResponse, Never>?
  private var started = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private(set) var refreshes = 0

  func waitForRefresh() async {
    if started { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func release() {
    pending?.resume(returning: tokenResponse(access: "new", refresh: "rotated"))
    pending = nil
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    refreshes += 1
    if refreshes > 1 { return tokenResponse(access: "duplicate", refresh: "duplicate-refresh") }
    return await withCheckedContinuation { continuation in
      pending = continuation
      started = true
      for observer in observers { observer.resume() }
      observers.removeAll()
    }
  }
}

private final class ObservedRefreshSecrets: SecretStore, Sendable {
  private let base = MemorySecretStore()
  let nextRead = Mutex<AsyncStream<Void>.Continuation?>(nil)
  func read(_ key: String) throws -> Data? {
    let value = try base.read(key)
    nextRead.withLock { observer in
      observer?.yield(())
      observer?.finish()
      observer = nil
    }
    return value
  }
  func write(_ data: Data, for key: String) throws { try base.write(data, for: key) }
  func delete(_ key: String) throws { try base.delete(key) }
}

@Test(arguments: [false, true])
func separateOAuthSessionsReuseRefreshCompletedWhileTheyWait(force: Bool) async throws {
  let secrets = ObservedRefreshSecrets()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)), for: "oauth")
  let transport = HeldRefreshHTTP()
  let first = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  let second = OAuthSession(
    configuration: configuration, secretKey: "oauth", secrets: secrets, transport: transport)
  let firstTask = Task { try await force ? first.refreshNow() : first.accessToken() }
  await transport.waitForRefresh()
  let read = AsyncStream<Void>.makeStream()
  secrets.nextRead.withLock { $0 = read.continuation }
  let secondTask = Task { try await force ? second.refreshNow() : second.accessToken() }
  // 第二个会话已读到过期记录后才放行首次刷新。
  for await _ in read.stream { break }
  await transport.release()
  #expect(try await firstTask.value == "new")
  #expect(try await secondTask.value == "new")
  #expect(await transport.refreshes == 1)
}
