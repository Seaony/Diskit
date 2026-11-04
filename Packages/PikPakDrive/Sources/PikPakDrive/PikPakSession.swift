import Core
import CryptoKit
import Foundation

public actor PikPakSession {
  public static let loginInvalidatedNotification = Notification.Name(
    "com.seaony.Kayoi.pikPakLoginInvalidated")
  public static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

  static let clientID = "YUMx5nI8ZU8Ap8pm"
  static let clientVersion = "2.0.0"
  static let packageName = "mypikpak.com"
  static let userRoot = "https://user.mypikpak.com"
  static let driveRoot = "https://api-drive.mypikpak.com"

  private struct CaptchaReply: Decodable {
    let token: String
    let expiresIn: Int64

    enum CodingKeys: String, CodingKey {
      case token = "captcha_token"
      case expiresIn = "expires_in"
    }
  }

  private struct CachedCaptcha {
    let token: String
    let expiresAt: Date
  }

  private let secretKey: String
  private let secrets: any SecretStore
  private let transport: any HTTPTransport
  private var captcha: [String: CachedCaptcha] = [:]
  private var refreshTask: Task<StoredPikPakAuthorization, Error>?
  private var didNotifyInvalidation = false

  public init(
    secretKey: String, secrets: any SecretStore = LoginKeychainStore(),
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.secretKey = secretKey
    self.secrets = secrets
    self.transport = transport
  }

  public func hasToken() throws -> Bool {
    guard let stored = try load() else { return false }
    return !stored.invalidated && !stored.accessToken.isEmpty && !stored.refreshToken.isEmpty
  }

  public func login(username: String, password: String) async throws -> PikPakAccount {
    guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty
    else { throw PikPakError.invalidCredentials }
    let deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let action = "POST:/v1/auth/signin"
    struct LoginRequest: Encodable {
      let username: String
      let password: String
      let clientID: String
      enum CodingKeys: String, CodingKey {
        case username, password
        case clientID = "client_id"
      }
    }
    var response: HTTPResponse?
    for attempt in 0..<2 {
      let captchaToken = try await captchaToken(
        action: action, username: username, deviceID: deviceID, userID: "", force: attempt > 0)
      var request = URLRequest(url: URL(string: Self.userRoot + "/v1/auth/signin")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(captchaToken, forHTTPHeaderField: "x-captcha-token")
      setCommonHeaders(on: &request, deviceID: deviceID)
      request.httpBody = try PikPakJSON.encode(
        LoginRequest(username: username, password: password, clientID: Self.clientID))
      let received = try await send(request)
      if attempt == 0, PikPakHTTP.isCaptchaInvalid(received) { continue }
      response = received
      break
    }
    guard let response else { throw PikPakError.invalidResponse }
    guard (200..<300).contains(response.status) else {
      if response.status == 400 || response.status == 401 || response.status == 403 {
        throw PikPakError.invalidCredentials
      }
      throw PikPakHTTP.map(status: response.status, body: response.body)
    }
    let token = try Self.decodeToken(response.body)
    let userID = token.subject ?? Self.userID(fromAccessToken: token.accessToken)
    guard !userID.isEmpty else { throw PikPakError.invalidResponse }
    let stored = StoredPikPakAuthorization(
      accessToken: token.accessToken, refreshToken: token.refreshToken,
      expiresAt: Date().timeIntervalSince1970 + Double(token.expiresIn), deviceID: deviceID,
      userID: userID)
    guard stored.expiresAt > Date().timeIntervalSince1970 else {
      throw PikPakError.invalidResponse
    }
    try persist(stored)
    didNotifyInvalidation = false
    return try await account()
  }

  public func account() async throws -> PikPakAccount {
    let userResponse = try await authorized(
      URLRequest(url: URL(string: Self.userRoot + "/v1/user/me")!))
    try PikPakHTTP.check(userResponse)
    guard let user = try? JSONDecoder().decode(PikPakUser.self, from: userResponse.body) else {
      throw PikPakError.invalidResponse
    }
    let aboutResponse = try await authorized(
      URLRequest(url: URL(string: Self.driveRoot + "/drive/v1/about")!))
    try PikPakHTTP.check(aboutResponse)
    guard let about = try? JSONDecoder().decode(PikPakAbout.self, from: aboutResponse.body),
      let quota = about.quota, let total = quota.limit, let used = quota.usage, total >= 0,
      used >= 0
    else { throw PikPakError.invalidResponse }
    return PikPakAccount(
      userID: user.subject ?? "", nickname: user.name ?? "", email: user.email ?? "", total: total,
      used: used)
  }

  public func authorized(_ original: URLRequest) async throws -> HTTPResponse {
    guard let url = original.url, Self.isAPI(url) else {
      throw PikPakError.invalidResponse
    }
    var authRetries = 0
    var captchaRetries = 0
    while true {
      let authorization = try await accessAuthorization()
      let action = (original.httpMethod ?? "GET").uppercased() + ":" + url.path
      let captchaToken = try await captchaToken(
        action: action, username: "", deviceID: authorization.deviceID,
        userID: authorization.userID)
      let request = prepare(
        original, authorization: authorization, captchaToken: captchaToken)
      let response = try await send(request)
      if captchaRetries == 0, PikPakHTTP.isCaptchaInvalid(response) {
        captcha.removeValue(forKey: action)
        captchaRetries += 1
        continue
      }
      if Self.requiresRefresh(response) {
        guard authRetries == 0 else { throw PikPakError.loginRequired }
        _ = try await refresh(rejected: authorization.accessToken)
        authRetries += 1
        continue
      }
      return response
    }
  }

  public func streamSigned(_ original: URLRequest) async throws -> HTTPStreamResponse {
    var request = original
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    do {
      return try await transport.stream(request)
    } catch {
      throw PikPakHTTP.transportError(error)
    }
  }

  public func sendSigned(_ original: URLRequest) async throws -> HTTPResponse {
    var request = original
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    return try await send(request)
  }

  private func load() throws -> StoredPikPakAuthorization? {
    guard let data = try secrets.read(secretKey) else { return nil }
    do { return try JSONDecoder().decode(StoredPikPakAuthorization.self, from: data) } catch {
      throw PikPakError.invalidResponse
    }
  }

  private func persist(_ value: StoredPikPakAuthorization) throws {
    try secrets.write(JSONEncoder().encode(value), for: secretKey)
  }

  private func accessAuthorization(rejected: String? = nil) async throws
    -> StoredPikPakAuthorization
  {
    guard let stored = try load(), !stored.invalidated, !stored.refreshToken.isEmpty else {
      try invalidate()
      throw PikPakError.loginRequired
    }
    if let rejected, stored.accessToken != rejected { return stored }
    if rejected == nil, stored.expiresAt > Date().timeIntervalSince1970 + 60,
      !stored.accessToken.isEmpty
    {
      return stored
    }
    return try await refresh(rejected: rejected)
  }

  private func refresh(rejected: String? = nil) async throws -> StoredPikPakAuthorization {
    if let stored = try load(), let rejected, stored.accessToken != rejected {
      return stored
    }
    if let refreshTask { return try await refreshTask.value }
    let task = Task { [transport] in
      guard let stored = try load(), !stored.refreshToken.isEmpty else {
        throw PikPakError.loginRequired
      }
      var request = URLRequest(url: URL(string: Self.userRoot + "/v1/auth/token")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue(
        "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      var form = URLComponents()
      form.queryItems = [
        URLQueryItem(name: "client_id", value: Self.clientID),
        URLQueryItem(name: "grant_type", value: "refresh_token"),
        URLQueryItem(name: "refresh_token", value: stored.refreshToken),
      ]
      guard let formBody = form.percentEncodedQuery else {
        throw PikPakError.invalidResponse
      }
      request.httpBody = Data(formBody.utf8)
      let response: HTTPResponse
      do {
        response = try await transport.send(request)
      } catch {
        throw PikPakHTTP.transportError(error)
      }
      if response.status < 500, response.status != 429,
        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
        body["error"] as? String == "invalid_grant"
      {
        throw PikPakError.loginRequired
      }
      guard (200..<300).contains(response.status) else {
        throw PikPakHTTP.map(status: response.status, body: response.body)
      }
      let token = try Self.decodeToken(response.body)
      let userID = token.subject ?? stored.userID
      let fresh = StoredPikPakAuthorization(
        accessToken: token.accessToken, refreshToken: token.refreshToken,
        expiresAt: Date().timeIntervalSince1970 + Double(token.expiresIn),
        deviceID: stored.deviceID, userID: userID)
      guard !fresh.accessToken.isEmpty, !fresh.refreshToken.isEmpty,
        fresh.expiresAt
          > Date()
          .timeIntervalSince1970
      else { throw PikPakError.invalidResponse }
      return fresh
    }
    refreshTask = task
    do {
      let fresh = try await task.value
      try persist(fresh)
      refreshTask = nil
      didNotifyInvalidation = false
      return fresh
    } catch {
      refreshTask = nil
      if (error as? PikPakError) == .loginRequired { try invalidate() }
      throw error
    }
  }

  private func invalidate() throws {
    if var stored = try load(), !stored.invalidated {
      stored.invalidated = true
      try persist(stored)
    }
    if !didNotifyInvalidation {
      didNotifyInvalidation = true
      NotificationCenter.default.post(
        name: Self.loginInvalidatedNotification, object: nil,
        userInfo: ["secretKey": secretKey])
    }
  }

  private func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      return try await transport.send(request)
    } catch {
      throw PikPakHTTP.transportError(error)
    }
  }

  private func captchaToken(
    action: String, username: String, deviceID: String, userID: String, force: Bool = false
  ) async throws -> String {
    if !force, let cached = captcha[action], cached.expiresAt > Date().addingTimeInterval(10) {
      return cached.token
    }
    if force { captcha.removeValue(forKey: action) }
    let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
    struct Meta: Encodable {
      let captchaSign: String?
      let clientVersion: String?
      let packageName: String?
      let timestamp: String?
      let userID: String?
      let username: String?
      enum CodingKeys: String, CodingKey {
        case captchaSign = "captcha_sign"
        case clientVersion = "client_version"
        case packageName = "package_name"
        case timestamp
        case userID = "user_id"
        case username
      }
    }
    struct Request: Encodable {
      let action: String
      let captchaToken: String
      let clientID: String
      let deviceID: String
      let meta: Meta
      enum CodingKeys: String, CodingKey {
        case action
        case captchaToken = "captcha_token"
        case clientID = "client_id"
        case deviceID = "device_id"
        case meta
      }
    }
    let meta: Meta
    if action == "POST:/v1/auth/signin" {
      meta = Meta(
        captchaSign: nil, clientVersion: nil, packageName: nil, timestamp: nil, userID: nil,
        username: username)
    } else {
      meta = Meta(
        captchaSign: Self.captchaSign(deviceID: deviceID, timestamp: timestamp),
        clientVersion: Self.clientVersion, packageName: Self.packageName, timestamp: timestamp,
        userID: userID, username: nil)
    }
    var request = URLRequest(
      url: URL(string: Self.userRoot + "/v1/shield/captcha/init")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    setCommonHeaders(on: &request, deviceID: deviceID)
    request.httpBody = try PikPakJSON.encode(
      Request(
        action: action, captchaToken: "", clientID: Self.clientID, deviceID: deviceID, meta: meta))
    let response = try await send(request)
    try PikPakHTTP.check(response)
    guard let reply = try? JSONDecoder().decode(CaptchaReply.self, from: response.body),
      !reply.token.isEmpty, reply.expiresIn > 0
    else { throw PikPakError.invalidResponse }
    captcha[action] = CachedCaptcha(
      token: reply.token,
      expiresAt: Date().addingTimeInterval(Double(reply.expiresIn)))
    return reply.token
  }

  private func prepare(
    _ original: URLRequest, authorization: StoredPikPakAuthorization, captchaToken: String
  ) -> URLRequest {
    var request = original
    request.timeoutInterval = 30
    request.setValue("Bearer " + authorization.accessToken, forHTTPHeaderField: "Authorization")
    request.setValue(captchaToken, forHTTPHeaderField: "x-captcha-token")
    request.setValue("https://mypikpak.com/", forHTTPHeaderField: "Referer")
    setCommonHeaders(on: &request, deviceID: authorization.deviceID)
    return request
  }

  private func setCommonHeaders(on request: inout URLRequest, deviceID: String) {
    request.setValue(Self.clientID, forHTTPHeaderField: "x-client-id")
    request.setValue(Self.clientVersion, forHTTPHeaderField: "x-client-version")
    request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://mypikpak.com/", forHTTPHeaderField: "Referer")
  }

  private static func isAPI(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "user.mypikpak.com" || host == "api-drive.mypikpak.com"
  }

  private static func requiresRefresh(_ response: HTTPResponse) -> Bool {
    if response.status == 401 { return true }
    guard
      let object = (try? JSONSerialization.jsonObject(with: response.body))
        as? [String: Any]
    else { return false }
    let reason = (object["error"] as? String)?.lowercased()
    let code = (object["error_code"] as? NSNumber)?.intValue
    return reason == "unauthenticated" || reason == "access_token_invalid"
      || reason == "access_token_expired" || code == 16
  }

  private static func decodeToken(_ data: Data) throws -> PikPakToken {
    do { return try JSONDecoder().decode(PikPakToken.self, from: data) } catch {
      throw PikPakError.invalidResponse
    }
  }

  private static func userID(fromAccessToken token: String) -> String {
    let fields = token.split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count > 1 else { return "" }
    var encoded = String(fields[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    return object["sub"] as? String ?? ""
  }

  static func captchaSign(deviceID: String, timestamp: String) -> String {
    let salts = [
      "C9qPpZLN8ucRTaTiUMWYS9cQvWOE", "+r6CQVxjzJV6LCV", "F", "pFJRC",
      "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt", "/750aCr4lm/Sly/c", "RB+DT/gZCrbV", "",
      "CyLsf7hdkIRxRm215hl", "7xHvLi2tOYP0Y92b", "ZGTXXxu8E/MIWaEDB+Sm/", "1UI3",
      "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO", "ihtqpG6FMt65+Xk+tWUH2",
      "NhXXU9rg4XXdzo7u5o",
    ]
    var value = clientID + clientVersion + packageName + deviceID + timestamp
    for salt in salts {
      value = md5Hex(Data((value + salt).utf8))
    }
    return "1." + value
  }

  private static func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
