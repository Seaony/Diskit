import Core
import CryptoKit
import Foundation
import Security

public actor OAuthSession {
  public static let invalidationNotification = Notification.Name(
    "com.seaony.Diskit.oauthDriveInvalidated")
  private let configuration: OAuthConfiguration
  private let secretKey: String
  private let secrets: RecoverableSecretStore
  private let transport: any HTTPTransport
  private nonisolated let requestLimit: HTTPConcurrencyLimit
  private var refreshing: Task<String, Error>?
  private var codeVerifier: String?
  private let makeDeadline: @Sendable () -> HTTPProgressDeadline

  public init(
    configuration: OAuthConfiguration, secretKey: String,
    secrets: any SecretStore = RuntimeStorage.current.secrets,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.init(
      configuration: configuration, secretKey: secretKey, secrets: secrets, transport: transport,
      makeDeadline: { HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest)) })
  }

  init(
    configuration: OAuthConfiguration, secretKey: String, secrets: any SecretStore,
    transport: any HTTPTransport, makeDeadline: @escaping @Sendable () -> HTTPProgressDeadline
  ) {
    self.configuration = configuration
    self.secretKey = secretKey
    self.secrets = secrets as? RecoverableSecretStore ?? RecoverableSecretStore(base: secrets)
    self.makeDeadline = makeDeadline
    let limit = HTTPConcurrencyLimit.shared(
      for: "oauth:" + secrets.refreshLockLocation(for: secretKey).path)
    requestLimit = limit
    self.transport = DiagnosticHTTPTransport(
      LimitedHTTPTransport(transport, limit: limit), category: .cloudDrive)
  }

  nonisolated func limited(_ transport: any HTTPTransport) -> any HTTPTransport {
    DiagnosticHTTPTransport(
      LimitedHTTPTransport(transport, limit: requestLimit), category: .cloudDrive)
  }

  public func hasToken() throws -> Bool {
    try loadToken() != nil
  }

  public func authorizationURL(state: String) throws -> URL {
    guard configuration.isConfigured, !state.isEmpty else { throw OAuthDriveError.configuration }
    var components = URLComponents(
      url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "state", value: state),
    ]
    if !configuration.scopes.isEmpty {
      items.append(
        URLQueryItem(
          name: "scope", value: configuration.scopes.joined(separator: configuration.scopeSeparator)
        )
      )
    }
    if configuration.usesPKCE {
      let verifier = try Self.pkceVerifier()
      codeVerifier = verifier
      let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
      items.append(URLQueryItem(name: "code_challenge", value: challenge))
      items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
    }
    items.append(
      contentsOf: configuration.additionalAuthorizationItems.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      })
    components.queryItems = (components.queryItems ?? []) + items
    guard let url = components.url else { throw OAuthDriveError.configuration }
    return url
  }

  @discardableResult
  public func exchange(code: String) async throws -> OAuthToken {
    guard !code.isEmpty else { throw OAuthDriveError.authorizationDenied }
    defer { codeVerifier = nil }
    var fields = [
      "grant_type": "authorization_code", "code": code,
      "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI,
    ]
    if !configuration.clientSecret.isEmpty {
      fields["client_secret"] = configuration.clientSecret
    }
    if configuration.usesPKCE {
      guard let codeVerifier else { throw OAuthDriveError.invalidResponse }
      fields["code_verifier"] = codeVerifier
    }
    let response = try await CloudDriveSupport.sendWithRetry(
      transport, tokenRequest(fields: fields), retrySafe: false)
    let token = try parseToken(response, previousRefresh: nil)
    try saveToken(token)
    return token
  }

  public func authorized(_ request: URLRequest, upload: Bool = false, retrySafe: Bool? = nil)
    async throws -> HTTPResponse
  {
    if upload { return try await performAuthorized(request, upload: true, retrySafe: retrySafe) }
    return try await makeDeadline().run {
      try await self.performAuthorized(request, upload: false, retrySafe: retrySafe)
    }
  }

  private func performAuthorized(_ request: URLRequest, upload: Bool, retrySafe: Bool?) async throws
    -> HTTPResponse
  {
    let access = try await accessToken()
    var firstRequest = request
    firstRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    let first = try await CloudDriveSupport.sendWithRetry(
      transport, firstRequest, upload: upload, retrySafe: retrySafe)
    guard first.status == 401 else { return first }
    _ = try await refreshNow(rejectedAccessToken: access)
    return try await withToken(request, upload: upload, retrySafe: retrySafe)
  }

  public func authorizedStream(_ request: URLRequest, retrySafe: Bool? = nil) async throws
    -> HTTPStreamResponse
  {
    try await makeDeadline().run {
      try await self.performAuthorizedStream(request, retrySafe: retrySafe)
    }
  }

  private func performAuthorizedStream(_ original: URLRequest, retrySafe: Bool?) async throws
    -> HTTPStreamResponse
  {
    var request = original
    let access = try await accessToken()
    request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    if let response = try await streamWithoutRejection(request, retrySafe: retrySafe) {
      return response
    }
    _ = try await refreshNow(rejectedAccessToken: access)
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    return try await CloudDriveSupport.streamWithRetry(transport, request, retrySafe: retrySafe)
  }

  private func streamWithoutRejection(_ request: URLRequest, retrySafe: Bool?) async throws
    -> HTTPStreamResponse?
  {
    let response = try await CloudDriveSupport.streamWithRetry(
      transport, request, retrySafe: retrySafe)
    // 刷新前释放拒绝响应，不能占着下载额度等待刷新。
    return response.response.status == 401 ? nil : response
  }

  public func invalidate() {
    try? secrets.delete(secretKey)
    NotificationCenter.default.post(
      name: Self.invalidationNotification,
      object: nil,
      userInfo: ["secretKey": secretKey])
  }

  public func accessToken() async throws -> String {
    try await makeDeadline().run { try await self.validToken() }
  }

  public func refreshNow(rejectedAccessToken: String? = nil) async throws -> String {
    try await makeDeadline().run {
      try await self.refresh(force: true, rejectedAccessToken: rejectedAccessToken)
    }
  }

  private func validToken() async throws -> String {
    let loaded = try loadToken()
    guard let loaded else { throw OAuthDriveError.loginRequired }
    if loaded.expiresAt > Date().addingTimeInterval(60) { return loaded.accessToken }
    return try await refresh(force: false, current: loaded)
  }

  private func withToken(_ request: URLRequest, upload: Bool, retrySafe: Bool?) async throws
    -> HTTPResponse
  {
    var request = request
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    return try await CloudDriveSupport.sendWithRetry(
      transport, request, upload: upload, retrySafe: retrySafe)
  }

  private func refresh(
    force: Bool, current: OAuthToken? = nil, rejectedAccessToken: String? = nil
  ) async throws -> String {
    if let rejectedAccessToken, let latest = try loadToken(),
      latest.accessToken != rejectedAccessToken
    {
      return latest.accessToken
    }
    if !force, let token = current, token.expiresAt > Date().addingTimeInterval(60) {
      return token.accessToken
    }
    if let refreshing { return try await SharedTaskWaiter.value(of: refreshing) }
    let observed = try loadToken()
    let task = Task<String, Error> {
      defer { refreshing = nil }
      let lease = try await secrets.acquireRefreshLock(for: secretKey)
      defer { secrets.releaseRefreshLock(lease, for: secretKey) }
      let stored = try loadToken()
      if let stored {
        if stored != observed, stored.expiresAt > Date().addingTimeInterval(60) {
          return stored.accessToken
        }
        if let rejectedAccessToken, stored.accessToken != rejectedAccessToken {
          return stored.accessToken
        }
        if !force, stored.expiresAt > Date().addingTimeInterval(60) {
          return stored.accessToken
        }
      }
      guard let refreshToken = stored?.refreshToken, !refreshToken.isEmpty else {
        invalidate()
        throw OAuthDriveError.loginRequired
      }
      do {
        var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        if configuration.refreshGrantIncludesClientCredentials {
          fields["client_id"] = configuration.clientID
          if !configuration.clientSecret.isEmpty {
            fields["client_secret"] = configuration.clientSecret
          }
        }
        if configuration.refreshGrantIncludesRedirectURI {
          fields["redirect_uri"] = configuration.redirectURI
        }
        let response = try await CloudDriveSupport.sendWithRetry(
          transport,
          tokenRequest(
            fields: fields, url: configuration.refreshTokenURL ?? configuration.tokenURL),
          retrySafe: false
        )
        let next = try parseToken(response, previousRefresh: refreshToken)
        try saveToken(next)
        return next.accessToken
      } catch {
        if case OAuthDriveError.loginRequired = error { invalidate() }
        throw error
      }
    }
    refreshing = task
    return try await SharedTaskWaiter.value(of: task)
  }

  private func tokenRequest(fields: [String: String], url: URL? = nil) -> URLRequest {
    let target = url ?? configuration.tokenURL
    switch configuration.tokenRequestPlacement {
    case .formBody:
      var request = URLRequest(url: target, timeoutInterval: RemoteTimeout.cloudRequest)
      request.httpMethod = configuration.tokenRequestMethod
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.formEncoded(fields).data(using: .utf8)
      return request
    case .query:
      var components = URLComponents(
        url: target, resolvingAgainstBaseURL: false)!
      components.percentEncodedQuery = Self.formEncoded(fields)
      var request = URLRequest(url: components.url!, timeoutInterval: RemoteTimeout.cloudRequest)
      request.httpMethod = configuration.tokenRequestMethod
      return request
    }
  }

  private func parseToken(_ response: HTTPResponse, previousRefresh: String?) throws -> OAuthToken {
    guard let topLevel = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else {
      if !(200..<300).contains(response.status) {
        throw tokenResponseError(status: response.status, payload: [:], body: response.body)
      }
      throw OAuthDriveError.invalidResponse
    }
    try throwIfTokenError(in: topLevel, status: response.status, body: response.body)
    let object: [String: Any]
    if let key = configuration.tokenResponseDataKey {
      guard let nested = topLevel[key] as? [String: Any] else {
        throw OAuthDriveError.invalidResponse
      }
      object = nested
    } else {
      object = topLevel
    }
    guard let access = object["access_token"] as? String, !access.isEmpty else {
      throw OAuthDriveError.invalidResponse
    }
    let expires =
      (object["expires_in"] as? NSNumber)?.doubleValue
      ?? Double(object["expires_in"] as? String ?? "")
      ?? 3_600
    return OAuthToken(
      accessToken: access,
      refreshToken: (object["refresh_token"] as? String) ?? previousRefresh,
      expiresAt: Date().addingTimeInterval(max(0, expires)))
  }

  private func throwIfTokenError(in payload: [String: Any], status: Int, body: Data) throws {
    if status == 429 || status >= 500 { throw OAuthDriveError.temporarilyUnavailable }
    let rejection = (payload["error"] ?? payload["error_code"] ?? payload["code"]) as? String
    if ["invalid_grant", "invalid_token", "token_revoked"].contains(rejection ?? "") {
      throw OAuthDriveError.loginRequired
    }
    let explicitSuccess = isSuccessfulState(payload["state"])
    if explicitSuccess, !(200..<300).contains(status) {
      throw tokenResponseError(status: status, payload: payload, body: body)
    }
    if payload["access_token"] is String { return }

    let code = integerValue(payload["code"]) ?? integerValue(payload["errno"])
    let rejectedCode: Set<Int> = [40_140_114, 40_140_115, 40_140_116]
    let rateLimitCode: Set<Int> = [429, 5_113, 40_140_117]
    if let code, rejectedCode.contains(code) {
      throw OAuthDriveError.loginRequired
    }
    if let code, rateLimitCode.contains(code) {
      throw OAuthDriveError.temporarilyUnavailable
    }
    if !(200..<300).contains(status) {
      throw tokenResponseError(status: status, payload: payload, body: body)
    }
    if payload["state"] != nil {
      // 明确返回失败（state 为假）时照实报出登录服务的原话和错误码
      guard explicitSuccess else {
        throw CloudDriveSupport.businessFailure(
          L("登录服务"), code: code, message: CloudDriveSupport.messageFields(body))
      }
      throw OAuthDriveError.invalidResponse
    }
  }

  private func tokenResponseError(status: Int, payload: [String: Any], body: Data) -> Error {
    let code =
      payload["error"] as? String
      ?? payload["error_code"] as? String
      ?? payload["code"] as? String
      ?? (integerValue(payload["code"]).map(String.init))
      ?? (integerValue(payload["errno"]).map(String.init))
    let numericCode = integerValue(payload["code"]) ?? integerValue(payload["errno"])
    let rateLimited =
      status == 429
      || status >= 500
      || numericCode == 429
      || numericCode == 5_113
      || numericCode == 40_140_117
      || code == "temporarily_unavailable"
    if rateLimited { return OAuthDriveError.temporarilyUnavailable }
    let rejected =
      ["invalid_grant", "invalid_token", "token_revoked"].contains(code ?? "")
      || [40_140_114, 40_140_115, 40_140_116].contains(numericCode ?? -1)
    if rejected { return OAuthDriveError.loginRequired }
    // 其他拒绝照实报出登录服务的原话和 HTTP 状态，不再笼统说「暂时无法连接」
    let message = CloudDriveSupport.serverMessage(body)
    return RemoteError.failed(
      EIO,
      message.isEmpty
        ? LF("登录服务返回 HTTP %@，没有附带说明", String(status))
        : LF("登录服务返回错误：%@（HTTP %@）", message, String(status)))
  }

  private func isSuccessfulState(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = integerValue(value) { return value != 0 }
    return true
  }

  private func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func loadToken() throws -> OAuthToken? {
    guard let data = try secrets.read(secretKey) else { return nil }
    return try JSONDecoder().decode(OAuthToken.self, from: data)
  }

  private func saveToken(_ token: OAuthToken) throws {
    try secrets.write(JSONEncoder().encode(token), for: secretKey)
  }

  private static func pkceVerifier() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 64)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw OAuthDriveError.invalidResponse
    }
    return Data(bytes).base64URLEncodedString
  }

  private static func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  private static func formEncoded(_ fields: [String: String]) -> String {
    fields.map {
      formEncode($0.key) + "=" + formEncode($0.value)
    }.sorted().joined(separator: "&")
  }
}

extension OAuthSession {
  public func tokenForTesting() throws -> OAuthToken? { try loadToken() }
}

extension Data {
  fileprivate var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
