import Core
import CryptoKit
import Foundation

struct StoredTianyiCookie: Codable, Equatable, Sendable {
  let name: String
  let value: String
  let domain: String
  let path: String
  let secure: Bool
  let expiresAt: TimeInterval?
}

struct TianyiCookieJar: Codable, Equatable, Sendable {
  private(set) var cookies: [StoredTianyiCookie]

  init(header: String, domain: String) throws {
    guard TianyiCookieJar.isSafe(header), !header.isEmpty else {
      throw TianyiError.invalidCookie
    }
    var parsed: [StoredTianyiCookie] = []
    let allowed = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
    for part in header.split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw TianyiError.invalidCookie }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else {
        throw TianyiError.invalidCookie
      }
      parsed.append(
        StoredTianyiCookie(
          name: name, value: value, domain: domain, path: "/", secure: true, expiresAt: nil))
    }
    guard parsed.contains(where: { $0.name == "SSON" && !$0.value.isEmpty }) else {
      throw TianyiError.invalidCookie
    }
    cookies = parsed
  }

  init(cookies: [StoredTianyiCookie]) {
    self.cookies = cookies
  }

  func header(for url: URL, trustedDomain: String) -> String? {
    guard Self.trusted(url, domain: trustedDomain) else { return nil }
    return Self.header(cookies: cookies, for: url)
  }

  mutating func merge(_ response: HTTPResponse, requestURL: URL, trustedDomain: String) {
    let sourceURL = response.url ?? requestURL
    guard Self.trusted(sourceURL, domain: trustedDomain),
      let raw = response.header("Set-Cookie")
    else { return }
    let incoming = HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": raw], for: sourceURL)
    for cookie in incoming {
      let domain = cookie.domain.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
      guard Self.trustedDomain(domain, base: trustedDomain) else { continue }
      let key = "\(cookie.name)\u{0}\(domain)\u{0}\(cookie.path)"
      cookies.removeAll {
        "\($0.name)\u{0}\($0.domain)\u{0}\($0.path)" == key
      }
      if cookie.expiresDate.map({ $0 <= Date() }) == true { continue }
      cookies.append(
        StoredTianyiCookie(
          name: cookie.name, value: cookie.value, domain: domain,
          path: cookie.path.isEmpty ? "/" : cookie.path, secure: cookie.isSecure,
          expiresAt: cookie.expiresDate?.timeIntervalSince1970))
    }
  }

  static func header(cookies: [StoredTianyiCookie], for url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
      return nil
    }
    let now = Date().timeIntervalSince1970
    let path = url.path.isEmpty ? "/" : url.path
    let values =
      cookies
      .filter { cookie in
        guard !cookie.name.isEmpty, cookie.expiresAt.map({ $0 > now }) != false,
          domainMatches(host: host, domain: cookie.domain),
          pathMatches(path, cookiePath: cookie.path)
        else { return false }
        return !cookie.secure || url.scheme?.lowercased() == "https"
      }
      .sorted {
        if $0.path.count == $1.path.count { return $0.name < $1.name }
        return $0.path.count > $1.path.count
      }
    guard !values.isEmpty else { return nil }
    return values.map { $0.name + "=" + $0.value }.joined(separator: "; ")
  }

  static func trusted(_ url: URL?, domain: String) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
    else { return false }
    return trustedDomain(host, base: domain)
  }

  private static func trustedDomain(_ host: String, base: String) -> Bool {
    let trusted = base.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return value == trusted || value.hasSuffix("." + trusted)
  }

  private static func domainMatches(host: String, domain: String) -> Bool {
    let value = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host == value || host.hasSuffix("." + value)
  }

  private static func pathMatches(_ path: String, cookiePath: String) -> Bool {
    guard path.hasPrefix(cookiePath) else { return false }
    if cookiePath == "/" || path.count == cookiePath.count { return true }
    let boundary = path.index(path.startIndex, offsetBy: cookiePath.count)
    return cookiePath.hasSuffix("/") || path[boundary] == "/"
  }

  private static func isSafe(_ header: String) -> Bool {
    header.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7f) }
  }
}

struct StoredTianyiSession: Codable, Equatable, Sendable {
  struct Credentials: Codable, Equatable, Sendable {
    let sessionKey: String
    let sessionSecret: String
  }

  var accessToken: String
  var refreshToken: String
  var personalCredentials: Credentials
  var familyCredentials: Credentials?
  var loginName: String
  var cookies: TianyiCookieJar

  func credentials(for kind: TianyiCredentialKind) throws -> Credentials {
    switch kind {
    case .personal:
      return personalCredentials
    case .family:
      guard let familyCredentials else { throw TianyiError.familyUnavailable }
      return familyCredentials
    }
  }
}

enum TianyiCredentialKind: Equatable, Sendable {
  case personal
  case family
}

extension TianyiStorageScope {
  var credentialKind: TianyiCredentialKind {
    switch self {
    case .personal: .personal
    case .family: .family
    }
  }
}

public actor TianyiSession {
  public static let loginInvalidatedNotification = Notification.Name(
    "com.seaony.Kayoi.tianyiLoginInvalidated")

  public nonisolated let configuration: TianyiConfiguration
  private let secretKey: String
  private let secrets: any SecretStore
  private let transport: any HTTPTransport
  private var didNotifyInvalidation = false

  public init(
    secretKey: String, secrets: any SecretStore = LoginKeychainStore(),
    configuration: TianyiConfiguration = .personal,
    transport: (any HTTPTransport)? = nil
  ) {
    self.secretKey = secretKey
    self.secrets = secrets as? RecoverableSecretStore ?? RecoverableSecretStore(base: secrets)
    self.configuration = configuration
    self.transport =
      transport ?? URLSessionHTTPTransport(cookieDomain: configuration.cookieDomain)
  }

  public func hasLogin() throws -> Bool {
    try load() != nil
  }

  @discardableResult
  public func login(cookie: String) async throws -> TianyiAccount {
    try validateConfiguredScope()
    let jar = try TianyiCookieJar(header: cookie, domain: configuration.cookieDomain)
    let fresh = try await sessionFromCookie(jar)
    _ = try fresh.credentials(for: configuration.scope.credentialKind)
    try persist(fresh)
    didNotifyInvalidation = false
    return try await account()
  }

  public func connect() async throws {
    try validateConfiguredScope()
    let state = try requireState()
    _ = try state.credentials(for: configuration.scope.credentialKind)
    _ = try await account()
  }

  public func account() async throws -> TianyiAccount {
    let response = try await api(
      path: "/portal/getUserSizeInfo.action", method: "GET", credentialKind: .personal)
    let capacity: TianyiCapacity = try TianyiJSON.decode(TianyiCapacity.self, from: response)
    let selected: TianyiCapacity.Capacity
    switch configuration.scope {
    case .personal:
      guard let cloud = capacity.cloudCapacityInfo else {
        throw TianyiError.invalidResponse
      }
      selected = cloud
    case .family:
      guard let family = capacity.familyCapacityInfo else {
        throw TianyiError.familyUnavailable
      }
      selected = family
    }
    guard selected.totalSize >= 0, selected.usedSize >= 0,
      selected.usedSize <= selected.totalSize
    else { throw TianyiError.invalidResponse }
    let current = try requireState()
    let userID = capacity.account ?? current.loginName
    return TianyiAccount(
      scope: configuration.scope,
      userID: userID,
      displayName: current.loginName.isEmpty ? userID : current.loginName,
      total: selected.totalSize, used: selected.usedSize)
  }

  public func familySpaces() async throws -> [TianyiFamilySpace] {
    let response = try await api(
      path: "/family/manage/getFamilyList.action", method: "GET", credentialKind: .family)
    let list: TianyiFamilyList = try TianyiJSON.decode(TianyiFamilyList.self, from: response)
    return (list.familyInfoResp ?? []).map { family in
      let name = family.remarkName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return TianyiFamilySpace(
        familyID: family.familyID.value,
        name: name.isEmpty ? family.familyID.value : name)
    }
  }

  func api(
    path: String, method: String, query: [URLQueryItem] = [], form: [String: String]? = nil,
    credentialKind: TianyiCredentialKind? = nil
  ) async throws -> HTTPResponse {
    let configuration = configuration
    let credentialKind = credentialKind ?? configuration.scope.credentialKind
    return try await sendWithRecovery { candidate in
      let credentials = try candidate.credentials(for: credentialKind)
      return try Self.makeSignedRequest(
        base: configuration.apiBaseURL, configuration: configuration, path: path,
        method: method, query: query,
        encryptedParams: nil, form: form, credentials: credentials)
    }
  }

  func upload(
    path: String, params: [String: String]
  ) async throws -> HTTPResponse {
    let credentialKind = configuration.scope.credentialKind
    let configuration = configuration
    return try await sendWithRecovery { candidate in
      let credentials = try candidate.credentials(for: credentialKind)
      let encrypted = try TianyiCrypto.encryptedParameters(
        params, sessionSecret: credentials.sessionSecret)
      return try Self.makeSignedRequest(
        base: configuration.uploadBaseURL, configuration: configuration, path: path,
        method: "GET", query: [],
        encryptedParams: encrypted, form: nil, credentials: credentials)
    }
  }

  func uploadChunk(url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
    guard url.scheme?.lowercased() == "https" else {
      throw TianyiError.invalidResponse
    }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "PUT"
    request.httpBody = body
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch {
      throw TianyiHTTP.transportError(error)
    }
    try TianyiHTTP.check(response)
    return response
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    var request = request
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      configuration.webBaseURL.absoluteString + "/web/main/", forHTTPHeaderField: "Referer")
    do {
      return try await transport.stream(request)
    } catch {
      throw TianyiHTTP.transportError(error)
    }
  }

  private func sessionFromCookie(_ initial: TianyiCookieJar) async throws -> StoredTianyiSession {
    var jar = initial
    var components = URLComponents(
      url: configuration.webBaseURL.appending(path: "/api/portal/unifyLoginForPC.action"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "appId", value: configuration.appID),
      URLQueryItem(name: "clientType", value: configuration.clientType),
      URLQueryItem(name: "returnURL", value: configuration.returnURL.absoluteString),
      URLQueryItem(name: "timeStamp", value: String(Self.millisecondsNow())),
    ]
    guard let unifyURL = components.url else { throw TianyiError.invalidResponse }
    var unify = URLRequest(url: unifyURL, timeoutInterval: 30)
    unify.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    let unifyResponse = try await send(unify)
    try Self.rejectInvalidGrant(unifyResponse)
    jar.merge(
      unifyResponse, requestURL: unifyURL, trustedDomain: configuration.cookieDomain)
    guard (200..<400).contains(unifyResponse.status) else {
      throw TianyiHTTP.map(status: unifyResponse.status, body: unifyResponse.body)
    }
    let locationURL = unifyResponse.header("Location").flatMap {
      URL(string: $0, relativeTo: unifyURL)
    }
    guard let redirectURL = unifyResponse.url ?? locationURL else {
      throw TianyiError.invalidResponse
    }

    var redirect = URLRequest(url: redirectURL, timeoutInterval: 30)
    redirect.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    if let cookie = jar.header(for: redirectURL, trustedDomain: configuration.cookieDomain) {
      redirect.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    let redirectResponse = try await send(redirect)
    try Self.rejectInvalidGrant(redirectResponse)
    jar.merge(
      redirectResponse, requestURL: redirectURL, trustedDomain: configuration.cookieDomain)
    guard (200..<400).contains(redirectResponse.status) else {
      throw TianyiHTTP.map(status: redirectResponse.status, body: redirectResponse.body)
    }
    let sessionURL = redirectResponse.url ?? redirectURL
    let fresh = try await exchangeSession(
      jar: &jar, queryName: "redirectURL", queryValue: sessionURL.absoluteString)
    return fresh
  }

  private func exchangeSession(
    jar: inout TianyiCookieJar, queryName: String, queryValue: String
  ) async throws -> StoredTianyiSession {
    guard
      var components = URLComponents(
        url: configuration.apiBaseURL.appending(path: "/getSessionForPC.action"),
        resolvingAgainstBaseURL: false)
    else { throw TianyiError.invalidResponse }
    components.queryItems = [
      URLQueryItem(name: "appId", value: configuration.appID),
      URLQueryItem(name: "clientType", value: configuration.pcClientType),
      URLQueryItem(name: "version", value: configuration.version),
      URLQueryItem(name: "channelId", value: configuration.channelID),
      URLQueryItem(name: "rand", value: Self.randomSuffix()),
      URLQueryItem(name: "returnType", value: "JSON"),
      URLQueryItem(name: queryName, value: queryValue),
    ]
    guard let url = components.url else { throw TianyiError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
    let response = try await send(request)
    try Self.rejectInvalidGrant(response)
    jar.merge(response, requestURL: url, trustedDomain: configuration.cookieDomain)
    try TianyiHTTP.check(response)
    let object = TianyiJSON.object(from: response.body)
    guard let sessionKey = Self.value(in: object, keys: ["sessionKey", "session_key"]),
      !sessionKey.isEmpty,
      let sessionSecret = Self.value(in: object, keys: ["sessionSecret", "session_secret"]),
      !sessionSecret.isEmpty
    else { throw TianyiError.invalidResponse }
    let familyKey = Self.value(
      in: object, keys: ["familySessionKey", "family_session_key"])
    let familySecret = Self.value(
      in: object, keys: ["familySessionSecret", "family_session_secret"])
    let familyCredentials: StoredTianyiSession.Credentials? =
      if let familyKey, let familySecret, !familyKey.isEmpty, !familySecret.isEmpty {
        StoredTianyiSession.Credentials(
          sessionKey: familyKey, sessionSecret: familySecret)
      } else {
        nil
      }
    return StoredTianyiSession(
      accessToken: Self.value(in: object, keys: ["accessToken", "access_token"]) ?? "",
      refreshToken: Self.value(in: object, keys: ["refreshToken", "refresh_token"]) ?? "",
      personalCredentials: .init(sessionKey: sessionKey, sessionSecret: sessionSecret),
      familyCredentials: familyCredentials,
      loginName: Self.value(in: object, keys: ["loginName", "login_name"]) ?? "",
      cookies: jar)
  }

  private func sendWithRecovery(
    _ build: @escaping @Sendable (StoredTianyiSession) throws -> URLRequest
  ) async throws -> HTTPResponse {
    let original = try requireState()
    var response = try await send(build(original))
    if TianyiHTTP.isAuthenticationFailure(response) {
      let restored = try await recover(original)
      response = try await send(build(restored))
      if TianyiHTTP.isAuthenticationFailure(response) {
        throw RemoteError.unauthorized
      }
    }
    try TianyiHTTP.check(response)
    return response
  }

  private func recover(_ rejected: StoredTianyiSession) async throws -> StoredTianyiSession {
    let lease = try await CredentialRefreshLock.acquire(
      at: secrets.refreshLockLocation(for: secretKey))
    defer { lease.release() }
    let current = try requireState()
    if current != rejected { return current }
    do {
      let restored = try await restore(current)
      try persist(restored)
      return restored
    } catch {
      if (error as? TianyiError) == .loginRequired {
        try invalidate()
        throw RemoteError.unauthorized
      }
      throw error
    }
  }

  private func restore(_ rejected: StoredTianyiSession) async throws -> StoredTianyiSession {
    var jar = rejected.cookies
    if !rejected.accessToken.isEmpty {
      do {
        let fresh = try await exchangeSession(
          jar: &jar, queryName: "accessToken", queryValue: rejected.accessToken)
        _ = try fresh.credentials(for: configuration.scope.credentialKind)
        return fresh
      } catch {
        guard
          (error as? RemoteError) == .unauthorized
            || (error as? TianyiError) == .loginRequired
            || (error as? TianyiError) == .familyUnavailable
        else { throw error }
      }
    }
    let sson = jar.cookies.first { $0.name == "SSON" && !$0.value.isEmpty }
    guard sson != nil else { throw TianyiError.loginRequired }
    return try await sessionFromCookie(jar)
  }

  private static func rejectInvalidGrant(_ response: HTTPResponse) throws {
    guard response.status < 500, response.status != 429,
      let body = TianyiJSON.object(from: response.body),
      (body["error"] ?? body["errorCode"] ?? body["code"]) as? String == "invalid_grant"
    else { return }
    throw TianyiError.loginRequired
  }

  private static func makeSignedRequest(
    base: URL, configuration: TianyiConfiguration, path: String, method: String,
    query: [URLQueryItem],
    encryptedParams: String?, form: [String: String]?,
    credentials: StoredTianyiSession.Credentials
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: base.appending(path: path), resolvingAgainstBaseURL: false)
    else { throw TianyiError.invalidResponse }
    components.queryItems =
      query
      + clientSuffix(configuration: configuration)
      + (encryptedParams.map { [URLQueryItem(name: "params", value: $0)] } ?? [])
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(
      of: "+", with: "%2B")
    guard let url = components.url else { throw TianyiError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = method.uppercased()
    let date = httpDate()
    let signature = TianyiCrypto.signature(
      sessionSecret: credentials.sessionSecret, sessionKey: credentials.sessionKey, operate: method,
      path: path, date: date, params: encryptedParams)
    request.setValue(date, forHTTPHeaderField: "Date")
    request.setValue(credentials.sessionKey, forHTTPHeaderField: "SessionKey")
    request.setValue(signature, forHTTPHeaderField: "Signature")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(configuration.webBaseURL.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    if let form {
      request.httpBody = formBody(form)
      request.setValue(
        "application/x-www-form-urlencoded;charset=UTF-8",
        forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      return try await transport.send(request)
    } catch {
      throw TianyiHTTP.transportError(error)
    }
  }

  private func requireState() throws -> StoredTianyiSession {
    guard let loaded = try load() else {
      throw RemoteError.unauthorized
    }
    return loaded
  }

  private func load() throws -> StoredTianyiSession? {
    guard let data = try secrets.read(secretKey) else { return nil }
    do {
      return try JSONDecoder().decode(StoredTianyiSession.self, from: data)
    } catch {
      throw TianyiError.invalidResponse
    }
  }

  private func persist(_ value: StoredTianyiSession) throws {
    try secrets.write(JSONEncoder().encode(value), for: secretKey)
  }

  private func invalidate() throws {
    try secrets.delete(secretKey)
    guard !didNotifyInvalidation else { return }
    didNotifyInvalidation = true
    NotificationCenter.default.post(
      name: Self.loginInvalidatedNotification, object: nil,
      userInfo: ["secretKey": secretKey])
  }

  private static func value(in object: [String: Any]?, keys: [String]) -> String? {
    guard let object else { return nil }
    for key in keys {
      if let value = object[key] as? String { return value }
      if let value = object[key] as? NSNumber { return value.stringValue }
    }
    return nil
  }

  private static func clientSuffix(configuration: TianyiConfiguration) -> [URLQueryItem] {
    [
      URLQueryItem(name: "clientType", value: configuration.pcClientType),
      URLQueryItem(name: "version", value: configuration.version),
      URLQueryItem(name: "channelId", value: configuration.channelID),
      URLQueryItem(name: "rand", value: randomSuffix()),
    ]
  }

  private static func formBody(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.keys.sorted().map {
      URLQueryItem(name: $0, value: values[$0])
    }
    return Data(
      (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
  }

  private static func httpDate(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }

  private static func randomSuffix() -> String {
    "\(Int.random(in: 0..<100_000))_\(Int.random(in: 0..<10_000_000_000))"
  }

  private static func millisecondsNow() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  private func validateConfiguredScope() throws {
    guard case .family(let familyID) = configuration.scope else { return }
    guard !familyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TianyiError.invalidFamilyID
    }
  }
}
