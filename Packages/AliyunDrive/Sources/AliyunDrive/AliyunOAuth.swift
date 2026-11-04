import Core
import Foundation

public enum AliyunError: Error, Equatable, LocalizedError, Sendable {
  case missingConfiguration, invalidState, loginRequired, invalidResponse, rateLimited
  case authorizationFailed(Int)
  public var errorDescription: String? {
    switch self {
    case .missingConfiguration: L("阿里云盘尚未在 Kayoi 中启用")
    case .invalidState: L("授权状态无效，请重新登录")
    case .loginRequired: L("阿里云盘需重新登录")
    case .invalidResponse: L("阿里云盘返回了无效的数据")
    case .rateLimited: L("阿里云盘请求过于频繁，请稍后重试")
    case .authorizationFailed(let status): String(format: L("阿里云盘授权失败（%d）"), status)
    }
  }
}

public struct AliyunConfiguration: Codable, Equatable, Sendable {
  public let clientID: String
  public let clientSecret: String
  public let redirectURI: String
  public init(clientID: String = "", clientSecret: String = "", redirectURI: String = "") {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.redirectURI = redirectURI
  }
  func validate() throws {
    guard !clientID.isEmpty, !clientSecret.isEmpty,
      let redirect = URL(string: redirectURI), redirect.scheme == "kayoi"
    else {
      throw AliyunError.missingConfiguration
    }
  }
  public func authorizationURL(state: String) throws -> URL {
    try validate()
    guard !state.isEmpty else { throw AliyunError.invalidState }
    var parts = URLComponents(string: "https://openapi.alipan.com/oauth/authorize")!
    parts.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "user:base,file:all:read,file:all:write"),
      URLQueryItem(name: "style", value: "folder"),
      URLQueryItem(name: "state", value: state),
    ]
    guard let url = parts.url else { throw AliyunError.missingConfiguration }
    return url
  }
}

public struct AliyunAccount: Sendable, Equatable {
  public let driveID: String
  public let userID: String
  public let nickname: String
  public let total: Int64
  public let used: Int64
  public let rootFolderID: String
  public init(
    driveID: String, userID: String, nickname: String, total: Int64, used: Int64,
    rootFolderID: String = "root"
  ) {
    self.driveID = driveID
    self.userID = userID
    self.nickname = nickname
    self.total = total
    self.used = used
    self.rootFolderID = rootFolderID
  }
}

struct AliyunStoredAuthorization: Codable, Sendable {
  var accessToken: String
  var refreshToken: String
  var expiresAt: TimeInterval
  var configuration: AliyunConfiguration
  var invalidated = false
}

public actor AliyunSession {
  public static let loginInvalidatedNotification = Notification.Name(
    "com.seaony.Kayoi.aliyunLoginInvalidated")
  private let secretKey: String
  private let secrets: any SecretStore
  private let configuration: AliyunConfiguration
  private let transport: any HTTPTransport
  private var refreshTask: Task<AliyunStoredAuthorization, Error>?
  private var didNotifyInvalidation = false
  private var activeRequests = 0
  private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

  public init(
    secretKey: String, secrets: any SecretStore = LoginKeychainStore(),
    configuration: AliyunConfiguration, transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.secretKey = secretKey
    self.secrets = secrets as? RecoverableSecretStore ?? RecoverableSecretStore(base: secrets)
    self.configuration = configuration
    self.transport = transport
  }
  public func authorizationURL(state: String) throws -> URL {
    try effectiveConfiguration().authorizationURL(state: state)
  }
  public func hasToken() throws -> Bool {
    guard let stored = try load() else { return false }
    return !stored.invalidated && !stored.accessToken.isEmpty && !stored.refreshToken.isEmpty
  }
  public func exchange(code: String) async throws {
    guard !code.isEmpty else { throw AliyunError.authorizationFailed(400) }
    let configuration = try effectiveConfiguration()
    let stored = try await token(
      configuration: configuration, grant: "authorization_code", value: code)
    try persist(stored)
    didNotifyInvalidation = false
  }

  public func authorized(_ original: URLRequest) async throws -> HTTPResponse {
    let official = Self.isOfficial(original)
    var authRetries = 0
    var rateRetries = 0
    while true {
      let authorization = official ? try await accessToken() : nil
      let response = try await limitedSend(
        Self.prepare(original, token: authorization?.accessToken))
      if response.status == 429 {
        guard rateRetries < 2 else { throw AliyunError.rateLimited }
        try await backoff(response, attempt: rateRetries)
        rateRetries += 1
        continue
      }
      if official {
        let action = Self.authAction(response)
        if action == .refresh, authRetries == 0, let authorization {
          _ = try await accessToken(rejected: authorization.accessToken)
          authRetries += 1
          continue
        }
        if action == .invalid { throw RemoteError.posix(EACCES) }
        if action != .none { throw AliyunError.loginRequired }
      }
      return response
    }
  }

  public func authorizedStream(_ original: URLRequest) async throws -> HTTPStreamResponse {
    let official = Self.isOfficial(original)
    var authRetries = 0
    var rateRetries = 0
    while true {
      let authorization = official ? try await accessToken() : nil
      let stream = try await limitedStream(
        Self.prepare(original, token: authorization?.accessToken))
      if (200..<300).contains(stream.response.status) { return stream }
      var bytes = Data()
      for try await data in stream.body {
        guard bytes.count + data.count <= 65_536 else { throw AliyunError.invalidResponse }
        bytes.append(data)
      }
      let response = HTTPResponse(
        status: stream.response.status, headers: stream.response.headers,
        body: bytes.isEmpty ? stream.response.body : bytes)
      if response.status == 429 {
        guard rateRetries < 2 else { throw AliyunError.rateLimited }
        try await backoff(response, attempt: rateRetries)
        rateRetries += 1
        continue
      }
      if official {
        let action = Self.authAction(response)
        if action == .refresh, authRetries == 0, let authorization {
          _ = try await accessToken(rejected: authorization.accessToken)
          authRetries += 1
          continue
        }
        if action == .invalid { throw RemoteError.posix(EACCES) }
        if action != .none { throw AliyunError.loginRequired }
      }
      return HTTPStreamResponse(
        response: response,
        body: AsyncThrowingStream { continuation in
          if !response.body.isEmpty { continuation.yield(response.body) }
          continuation.finish()
        })
    }
  }

  public func account() async throws -> AliyunAccount {
    let drive = try await authorized(Self.jsonRequest("/adrive/v1.0/user/getDriveInfo", body: [:]))
    let space = try await authorized(Self.jsonRequest("/adrive/v1.0/user/getSpaceInfo", body: [:]))
    guard (200..<300).contains(drive.status), (200..<300).contains(space.status),
      let metadata = try JSONSerialization.jsonObject(with: drive.body) as? [String: Any],
      let driveID = metadata["default_drive_id"] as? String, !driveID.isEmpty,
      let userID = metadata["user_id"] as? String, !userID.isEmpty,
      let name = metadata["name"] as? String,
      let root = try JSONSerialization.jsonObject(with: space.body) as? [String: Any],
      let personal = root["personal_space_info"] as? [String: Any],
      let total = personal["total_size"] as? NSNumber,
      let used = personal["used_size"] as? NSNumber,
      total.int64Value >= 0, used.int64Value >= 0, used.int64Value <= total.int64Value
    else {
      throw AliyunError.invalidResponse
    }
    let folderID = metadata["folder_id"] as? String
    return AliyunAccount(
      driveID: driveID, userID: userID, nickname: name,
      total: total.int64Value, used: used.int64Value,
      rootFolderID: folderID?.isEmpty == false ? folderID! : "root")
  }

  private func load() throws -> AliyunStoredAuthorization? {
    guard let data = try secrets.read(secretKey) else { return nil }
    do { return try JSONDecoder().decode(AliyunStoredAuthorization.self, from: data) } catch {
      throw AliyunError.invalidResponse
    }
  }
  private func persist(_ authorization: AliyunStoredAuthorization) throws {
    try secrets.write(JSONEncoder().encode(authorization), for: secretKey)
  }
  private func effectiveConfiguration() throws -> AliyunConfiguration {
    let value: AliyunConfiguration
    if configuration.clientID.isEmpty && configuration.clientSecret.isEmpty
      && configuration.redirectURI.isEmpty
    {
      value = try load()?.configuration ?? configuration
    } else {
      value = configuration
    }
    try value.validate()
    return value
  }
  private func accessToken(rejected: String? = nil) async throws -> AliyunStoredAuthorization {
    guard let stored = try load(), !stored.invalidated, !stored.refreshToken.isEmpty else {
      try invalidate()
      throw AliyunError.loginRequired
    }
    if let rejected, stored.accessToken != rejected { return stored }
    if rejected == nil, stored.expiresAt > Date().timeIntervalSince1970 + 60,
      !stored.accessToken.isEmpty
    {
      return stored
    }
    if let refreshTask { return try await refreshTask.value }
    let task = Task {
      let lease = try await CredentialRefreshLock.acquire(
        at: secrets.refreshLockLocation(for: secretKey))
      defer { lease.release() }
      do {
        guard let stored = try load(), !stored.invalidated, !stored.refreshToken.isEmpty else {
          throw AliyunError.loginRequired
        }
        if let rejected, stored.accessToken != rejected { return stored }
        if rejected == nil, stored.expiresAt > Date().timeIntervalSince1970 + 60,
          !stored.accessToken.isEmpty
        {
          return stored
        }
        let configuration = try effectiveConfiguration()
        let fresh = try await self.token(
          configuration: configuration, grant: "refresh_token", value: stored.refreshToken)
        try self.persist(fresh)
        self.didNotifyInvalidation = false
        return fresh
      } catch {
        if (error as? AliyunError) == .loginRequired { try self.invalidate() }
        throw error
      }
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }
  private func invalidate() throws {
    if var record = try load(), !record.invalidated {
      record.invalidated = true
      try persist(record)
    }
    if !didNotifyInvalidation {
      didNotifyInvalidation = true
      NotificationCenter.default.post(
        name: Self.loginInvalidatedNotification, object: nil,
        userInfo: ["secretKey": secretKey])
    }
  }
  private struct TokenReply: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
  }
  private func token(configuration: AliyunConfiguration, grant: String, value: String) async throws
    -> AliyunStoredAuthorization
  {
    let request = try Self.jsonRequest(
      "/oauth/access_token",
      body: [
        "client_id": configuration.clientID, "client_secret": configuration.clientSecret,
        "grant_type": grant, grant == "authorization_code" ? "code" : "refresh_token": value,
      ])
    var retries = 0
    while true {
      let response = try await limitedSend(request)
      if response.status == 429 {
        guard retries < 2 else { throw AliyunError.rateLimited }
        try await backoff(response, attempt: retries)
        retries += 1
        continue
      }
      if grant == "refresh_token", response.status < 500,
        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
        let code = (body["error"] ?? body["code"]) as? String,
        ["invalid_grant", "RefreshTokenExpired"].contains(code)
      {
        throw AliyunError.loginRequired
      }
      guard (200..<300).contains(response.status) else {
        throw AliyunError.authorizationFailed(response.status)
      }
      let reply = try JSONDecoder().decode(TokenReply.self, from: response.body)
      guard !reply.access_token.isEmpty, !reply.refresh_token.isEmpty, reply.expires_in > 0,
        reply.expires_in.isFinite
      else { throw AliyunError.invalidResponse }
      return AliyunStoredAuthorization(
        accessToken: reply.access_token, refreshToken: reply.refresh_token,
        expiresAt: Date().timeIntervalSince1970 + reply.expires_in, configuration: configuration)
    }
  }
  private enum AuthAction { case none, refresh, invalid }
  private static func authAction(_ response: HTTPResponse) -> AuthAction {
    let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    let code = body?["code"] as? String
    if response.status == 403 && code == "PermissionDenied" { return .invalid }
    if response.status == 401 || code == "AccessTokenInvalid" || code == "AccessTokenExpired" {
      return .refresh
    }
    return .none
  }
  private static func isOfficial(_ request: URLRequest) -> Bool {
    request.url?.scheme == "https" && request.url?.host?.lowercased() == "openapi.alipan.com"
  }
  private static func prepare(_ original: URLRequest, token: String?) -> URLRequest {
    var request = original
    if let token {
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 30
    } else {
      request.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    return request
  }
  static func jsonRequest(_ path: String, body: [String: String]) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://openapi.alipan.com" + path)!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
  static func retryDelay(_ response: HTTPResponse, attempt: Int, now: Date = Date()) -> TimeInterval
  {
    if let value = response.header("x-retry-after"), let milliseconds = Double(value),
      milliseconds >= 0, milliseconds.isFinite
    {
      return milliseconds / 1000
    }
    if let value = response.header("Retry-After") {
      if let seconds = Double(value), seconds >= 0, seconds.isFinite { return seconds }
      let parser = DateFormatter()
      parser.locale = Locale(identifier: "en_US_POSIX")
      parser.timeZone = TimeZone(secondsFromGMT: 0)
      parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      if let date = parser.date(from: value) { return max(0, date.timeIntervalSince(now)) }
    }
    return attempt == 0 ? 1 : 2
  }
  private func backoff(_ response: HTTPResponse, attempt: Int) async throws {
    let delay = Self.retryDelay(response, attempt: attempt)
    guard delay <= 30 else { throw AliyunError.rateLimited }
    try await Task.sleep(for: .seconds(delay))
  }
  private func acquire() async throws {
    try Task.checkCancellation()
    if activeRequests < 4 {
      activeRequests += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiting.append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiting(id) }
    }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }
  private func cancelWaiting(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
    waiting.remove(at: index).1.resume(throwing: CancellationError())
  }
  private func release() {
    if waiting.isEmpty { activeRequests -= 1 } else { waiting.removeFirst().1.resume() }
  }
  private func limitedSend(_ request: URLRequest) async throws -> HTTPResponse {
    try await acquire()
    defer { release() }
    return try await transport.send(request)
  }
  private func limitedStream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    try await acquire()
    do {
      let upstream = try await transport.stream(request)
      let cursor = AliyunStreamCursor(upstream.body, release: { await self.release() })
      return HTTPStreamResponse(
        response: upstream.response,
        body: AsyncThrowingStream(unfolding: { try await cursor.next() }))
    } catch {
      release()
      throw error
    }
  }
}

private actor AliyunStreamCursor {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private let release: @Sendable () async -> Void
  private var finished = false
  init(_ stream: AsyncThrowingStream<Data, Error>, release: @escaping @Sendable () async -> Void) {
    iterator = stream.makeAsyncIterator()
    self.release = release
  }
  deinit {
    if !finished {
      let release = release
      Task { await release() }
    }
  }
  func next() async throws -> Data? {
    if finished { return nil }
    guard var current = iterator else { throw AliyunError.invalidResponse }
    iterator = nil
    do {
      let data = try await current.next(isolation: self)
      if data == nil {
        finished = true
        await release()
      } else {
        iterator = current
      }
      return data
    } catch {
      finished = true
      await release()
      throw error
    }
  }
}
