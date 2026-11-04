import Core
import CryptoKit
import Foundation
import Security

public struct OAuthConfiguration: Sendable, Equatable {
  public let clientID: String
  public let clientSecret: String
  public let authorizationURL: URL
  public let tokenURL: URL
  public let refreshTokenURL: URL?
  public let redirectURI: String
  public let scopes: [String]
  public let additionalAuthorizationItems: [String: String]
  public let scopeSeparator: String
  public let tokenRequestMethod: String
  public let tokenRequestPlacement: OAuthTokenRequestPlacement
  public let tokenResponseDataKey: String?
  public let refreshGrantIncludesClientCredentials: Bool
  public let refreshGrantIncludesRedirectURI: Bool
  public let usesPKCE: Bool
  public init(
    clientID: String, clientSecret: String, authorizationURL: URL, tokenURL: URL,
    refreshTokenURL: URL? = nil, redirectURI: String, scopes: [String],
    additionalAuthorizationItems: [String: String] = [:], scopeSeparator: String = " ",
    tokenRequestMethod: String = "POST",
    tokenRequestPlacement: OAuthTokenRequestPlacement = .formBody,
    tokenResponseDataKey: String? = nil,
    refreshGrantIncludesClientCredentials: Bool = true,
    refreshGrantIncludesRedirectURI: Bool = false,
    usesPKCE: Bool = false
  ) {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.authorizationURL = authorizationURL
    self.tokenURL = tokenURL
    self.refreshTokenURL = refreshTokenURL
    self.redirectURI = redirectURI
    self.scopes = scopes
    self.additionalAuthorizationItems = additionalAuthorizationItems
    self.scopeSeparator = scopeSeparator
    self.tokenRequestMethod = tokenRequestMethod
    self.tokenRequestPlacement = tokenRequestPlacement
    self.tokenResponseDataKey = tokenResponseDataKey
    self.refreshGrantIncludesClientCredentials = refreshGrantIncludesClientCredentials
    self.refreshGrantIncludesRedirectURI = refreshGrantIncludesRedirectURI
    self.usesPKCE = usesPKCE
  }
  public var isConfigured: Bool {
    !clientID.isEmpty && !redirectURI.isEmpty
  }
}

public enum OAuthTokenRequestPlacement: Sendable, Equatable {
  case formBody
  case query
}

public struct OAuthToken: Codable, Sendable, Equatable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date
  public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

public struct OAuthProfile: Sendable, Equatable {
  public let userID: String
  public let nickname: String
  public let avatarURL: String?
  public init(userID: String, nickname: String, avatarURL: String? = nil) {
    self.userID = userID
    self.nickname = nickname
    self.avatarURL = avatarURL
  }
}

public protocol OAuthProfileProviding: Sendable {
  func profile() async throws -> OAuthProfile
}

public enum OAuthDriveError: Error, LocalizedError, Sendable {
  case configuration, loginRequired, temporarilyUnavailable, invalidResponse, authorizationDenied
  public var errorDescription: String? {
    switch self {
    case .configuration: L("此网盘尚未在 Kayoi 中启用")
    case .loginRequired: L("登录已失效，请重新登录")
    case .temporarilyUnavailable: L("服务暂时无法连接，请稍后重试")
    case .invalidResponse: L("服务返回了无法识别的数据")
    case .authorizationDenied: L("没有完成授权，请重新登录")
    }
  }
}

public actor OAuthSession {
  public static let invalidationNotification = Notification.Name(
    "com.seaony.Kayoi.oauthDriveInvalidated")
  private let configuration: OAuthConfiguration
  private let secretKey: String
  private let secrets: any SecretStore
  private let transport: any HTTPTransport
  private var token: OAuthToken?
  private var refreshing: Task<String, Error>?
  private var codeVerifier: String?

  public init(
    configuration: OAuthConfiguration, secretKey: String,
    secrets: any SecretStore = LoginKeychainStore(),
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.configuration = configuration
    self.secretKey = secretKey
    self.secrets = secrets
    self.transport = transport
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
      transport, tokenRequest(fields: fields))
    let token = try parseToken(response, previousRefresh: nil)
    try saveToken(token)
    return token
  }

  public func authorized(_ request: URLRequest) async throws -> HTTPResponse {
    let access = try await validToken()
    var firstRequest = request
    firstRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    let first = try await CloudDriveSupport.sendWithRetry(transport, firstRequest)
    guard first.status == 401 else { return first }
    _ = try await refresh(force: true, rejectedAccessToken: access)
    let retried = try await withToken(request)
    return retried
  }

  public func authorizedStream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    var request = request
    let access = try await validToken()
    request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    let response = try await CloudDriveSupport.streamWithRetry(transport, request)
    if response.response.status == 401 {
      _ = try await refresh(force: true, rejectedAccessToken: access)
      request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
      let retried = try await CloudDriveSupport.streamWithRetry(transport, request)
      return retried
    }
    return response
  }

  public func invalidate() {
    token = nil
    try? secrets.delete(secretKey)
    NotificationCenter.default.post(
      name: Self.invalidationNotification,
      object: nil,
      userInfo: ["secretKey": secretKey])
  }

  public func accessToken() async throws -> String {
    try await validToken()
  }

  public func refreshNow() async throws -> String {
    try await refresh(force: true)
  }

  private func validToken() async throws -> String {
    let loaded = try loadToken()
    guard let loaded else { throw OAuthDriveError.loginRequired }
    if loaded.expiresAt > Date().addingTimeInterval(60) { return loaded.accessToken }
    return try await refresh(force: false, current: loaded)
  }

  private func withToken(_ request: URLRequest) async throws -> HTTPResponse {
    var request = request
    request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
    return try await CloudDriveSupport.sendWithRetry(transport, request)
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
    if let refreshing { return try await refreshing.value }
    let stored: OAuthToken?
    if let current {
      stored = current
    } else {
      stored = try loadToken()
    }
    guard let refreshToken = stored?.refreshToken,
      !refreshToken.isEmpty
    else {
      invalidate()
      throw OAuthDriveError.loginRequired
    }
    let task = Task<String, Error> {
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
        tokenRequest(fields: fields, url: configuration.refreshTokenURL ?? configuration.tokenURL))
      let next = try parseToken(response, previousRefresh: refreshToken)
      try saveToken(next)
      token = next
      return next.accessToken
    }
    refreshing = task
    do {
      let value = try await task.value
      refreshing = nil
      return value
    } catch {
      refreshing = nil
      if case OAuthDriveError.loginRequired = error {
        invalidate()
      }
      throw error
    }
  }

  private func tokenRequest(fields: [String: String], url: URL? = nil) -> URLRequest {
    let target = url ?? configuration.tokenURL
    switch configuration.tokenRequestPlacement {
    case .formBody:
      var request = URLRequest(url: target, timeoutInterval: 30)
      request.httpMethod = configuration.tokenRequestMethod
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.formEncoded(fields).data(using: .utf8)
      return request
    case .query:
      var components = URLComponents(
        url: target, resolvingAgainstBaseURL: false)!
      components.percentEncodedQuery = Self.formEncoded(fields)
      var request = URLRequest(url: components.url!, timeoutInterval: 30)
      request.httpMethod = configuration.tokenRequestMethod
      return request
    }
  }

  private func parseToken(_ response: HTTPResponse, previousRefresh: String?) throws -> OAuthToken {
    guard let topLevel = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else {
      if !(200..<300).contains(response.status) {
        throw tokenResponseError(status: response.status, payload: [:])
      }
      throw OAuthDriveError.invalidResponse
    }
    try throwIfTokenError(in: topLevel, status: response.status)
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

  private func throwIfTokenError(in payload: [String: Any], status: Int) throws {
    if status == 429 || status >= 500 { throw OAuthDriveError.temporarilyUnavailable }
    let rejection = (payload["error"] ?? payload["error_code"] ?? payload["code"]) as? String
    if ["invalid_grant", "invalid_token", "token_revoked"].contains(rejection ?? "") {
      throw OAuthDriveError.loginRequired
    }
    let explicitSuccess = isSuccessfulState(payload["state"])
    if explicitSuccess, !(200..<300).contains(status) {
      throw tokenResponseError(status: status, payload: payload)
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
      throw tokenResponseError(status: status, payload: payload)
    }
    if payload["state"] != nil {
      throw OAuthDriveError.invalidResponse
    }
  }

  private func tokenResponseError(status: Int, payload: [String: Any]) -> OAuthDriveError {
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
    if rateLimited { return .temporarilyUnavailable }
    let rejected =
      ["invalid_grant", "invalid_token", "token_revoked"].contains(code ?? "")
      || [40_140_114, 40_140_115, 40_140_116].contains(numericCode ?? -1)
    return rejected ? .loginRequired : .temporarilyUnavailable
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
    if let token { return token }
    guard let data = try secrets.read(secretKey) else { return nil }
    token = try JSONDecoder().decode(OAuthToken.self, from: data)
    return token
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
