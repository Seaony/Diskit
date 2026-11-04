import Core
import Foundation

public enum QuarkError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidCookie, loginRequired, invalidResponse
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { self == .invalidResponse ? Int(EIO) : Int(EACCES) }
  public var errorDescription: String? {
    switch self {
    case .invalidCookie: L("登录信息不完整，请重新扫码登录")
    case .loginRequired: L("夸克网盘需重新登录")
    case .invalidResponse: L("夸克网盘返回了无效的数据")
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

public struct QuarkAccount: Sendable, Equatable {
  public let userID: String
  public let nickname: String
  public let total: Int64
  public let used: Int64
  public init(userID: String, nickname: String, total: Int64, used: Int64) {
    self.userID = userID
    self.nickname = nickname
    self.total = total
    self.used = used
  }
}

private struct QuarkCookie {
  var values: [String: String]
  init(_ header: String) throws {
    guard !header.isEmpty, header.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else {
      throw QuarkError.invalidCookie
    }
    let allowed = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
    var values: [String: String] = [:]
    for item in header.split(separator: ";") {
      let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw QuarkError.invalidCookie }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else {
        throw QuarkError.invalidCookie
      }
      values[name] = value
    }
    self.values = values
  }
  var valid: Bool { !(values["__puus"] ?? "").isEmpty && !(values["__pus"] ?? "").isEmpty }
  var header: String { values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; ") }
  func merging(_ response: HTTPResponse, from url: URL, cookieDomain: String) -> QuarkCookie {
    let sourceURL = response.url ?? url
    guard QuarkSession.trusted(sourceURL, domain: cookieDomain),
      let value = response.header("Set-Cookie")
    else {
      return self
    }
    var result = self
    let incoming = HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": value], for: sourceURL)
    let host = sourceURL.host?.lowercased() ?? ""
    for cookie in incoming {
      let domain = cookie.domain.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
      guard domain == cookieDomain || domain.hasSuffix("." + cookieDomain),
        host == domain || host.hasSuffix("." + domain)
      else { continue }
      let maxAge = cookie.properties?[.maximumAge].map { String(describing: $0) }.flatMap(Int.init)
      if cookie.expiresDate.map({ $0 <= Date() }) == true || maxAge.map({ $0 <= 0 }) == true {
        result.values.removeValue(forKey: cookie.name)
      } else {
        result.values[cookie.name] = cookie.value
      }
    }
    return result
  }
}

public enum QuarkCloudService: String, Sendable {
  case quark, uc
}

public struct QuarkCloudConfiguration: Sendable, Equatable {
  public let service: QuarkCloudService
  public let cookieDomain: String
  public let loginURL: URL
  public let refererURL: String
  public let accountURL: URL
  public let apiBase: String
  public let clientParameter: String
  public let userAgent: String

  public static let quark = QuarkCloudConfiguration(
    service: .quark, cookieDomain: "quark.cn",
    loginURL: URL(string: "https://pan.quark.cn/")!,
    refererURL: "https://pan.quark.cn/",
    accountURL: URL(string: "https://pan.quark.cn/account/info")!,
    apiBase: "https://drive.quark.cn/1/clouddrive", clientParameter: "ucpro",
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  )

  public static let uc = QuarkCloudConfiguration(
    service: .uc, cookieDomain: "uc.cn",
    loginURL: URL(string: "https://drive.uc.cn/")!,
    refererURL: "https://drive.uc.cn/",
    accountURL: URL(string: "https://drive.uc.cn/account/info")!,
    apiBase: "https://pc-api.uc.cn/1/clouddrive", clientParameter: "UCBrowser",
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
  )
}

public actor QuarkSession {
  public static let loginInvalidatedNotification = Notification.Name(
    "com.seaony.Kayoi.quarkLoginInvalidated")
  public static let userAgent = QuarkCloudConfiguration.quark.userAgent
  public nonisolated let configuration: QuarkCloudConfiguration
  private let secretKey: String
  private let secrets: any SecretStore
  private let transport: any HTTPTransport
  private var didNotifyInvalidation = false
  public init(
    secretKey: String, secrets: any SecretStore = LoginKeychainStore(),
    configuration: QuarkCloudConfiguration = .quark,
    transport: (any HTTPTransport)? = nil
  ) {
    self.secretKey = secretKey
    self.secrets = secrets
    self.configuration = configuration
    self.transport =
      transport ?? URLSessionHTTPTransport(cookieDomain: configuration.cookieDomain)
  }
  public func hasCookie() throws -> Bool { try storedCookie()?.valid == true }

  public func login(cookie: String) async throws -> QuarkAccount {
    var candidate = try QuarkCookie(cookie)
    guard candidate.valid else { throw QuarkError.invalidCookie }
    let infoRequest = Self.accountRequest(configuration)
    let infoResponse = try await transport.send(
      Self.prepare(infoRequest, cookie: candidate, configuration: configuration))
    candidate = candidate.merging(
      infoResponse, from: infoRequest.url!, cookieDomain: configuration.cookieDomain)
    guard Self.trusted(infoResponse.url ?? infoRequest.url, domain: configuration.cookieDomain)
    else {
      throw QuarkError.invalidResponse
    }
    try Self.check(infoResponse, request: infoRequest)
    let info = try Self.identity(infoResponse)
    let spaceRequest = Self.spaceRequest(configuration)
    let spaceResponse = try await transport.send(
      Self.prepare(spaceRequest, cookie: candidate, configuration: configuration))
    candidate = candidate.merging(
      spaceResponse, from: spaceRequest.url!, cookieDomain: configuration.cookieDomain)
    guard Self.trusted(spaceResponse.url ?? spaceRequest.url, domain: configuration.cookieDomain)
    else {
      throw QuarkError.invalidResponse
    }
    try Self.check(spaceResponse, request: spaceRequest)
    let space = try Self.space(spaceResponse)
    guard candidate.valid else { throw QuarkError.loginRequired }
    try secrets.write(Data(candidate.header.utf8), for: secretKey)
    didNotifyInvalidation = false
    return QuarkAccount(userID: info.0, nickname: info.1, total: space.0, used: space.1)
  }

  public func account() async throws -> QuarkAccount {
    let info = try Self.identity(await authorized(Self.accountRequest(configuration)))
    let space = try Self.space(await authorized(Self.spaceRequest(configuration)))
    return QuarkAccount(userID: info.0, nickname: info.1, total: space.0, used: space.1)
  }

  public func authorized(_ original: URLRequest) async throws -> HTTPResponse {
    let cookie = try requireCookie()
    let response = try await transport.send(
      Self.prepare(original, cookie: cookie, configuration: configuration))
    try process(response, request: original, sent: cookie)
    return response
  }
  public func authorizedStream(_ original: URLRequest) async throws -> HTTPStreamResponse {
    let cookie = try requireCookie()
    let stream = try await transport.stream(
      Self.prepare(original, cookie: cookie, configuration: configuration))
    guard Self.trusted(original.url, domain: configuration.cookieDomain) else { return stream }
    guard
      Self.trusted(
        stream.response.url ?? original.url, domain: configuration.cookieDomain)
    else {
      if Self.isAPI(original) { throw QuarkError.invalidResponse }
      return stream
    }
    if (200..<300).contains(stream.response.status), !Self.isAPI(original) {
      try process(stream.response, request: original, sent: cookie)
      return stream
    }
    var data = Data()
    for try await chunk in stream.body {
      guard data.count + chunk.count <= 1_048_576 else { throw QuarkError.invalidResponse }
      data.append(chunk)
    }
    let response = HTTPResponse(
      status: stream.response.status, headers: stream.response.headers,
      body: data.isEmpty ? stream.response.body : data, url: stream.response.url)
    try process(response, request: original, sent: cookie)
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream { continuation in
        if !response.body.isEmpty { continuation.yield(response.body) }
        continuation.finish()
      })
  }

  private func storedCookie() throws -> QuarkCookie? {
    guard let data = try secrets.read(secretKey), let header = String(data: data, encoding: .utf8)
    else { return nil }
    return try? QuarkCookie(header)
  }
  private func requireCookie() throws -> QuarkCookie {
    guard let cookie = try storedCookie(), cookie.valid else {
      notifyInvalidation()
      throw QuarkError.loginRequired
    }
    return cookie
  }
  private func process(_ response: HTTPResponse, request: URLRequest, sent: QuarkCookie) throws {
    guard Self.trusted(request.url, domain: configuration.cookieDomain), let url = request.url
    else { return }
    guard Self.trusted(response.url ?? url, domain: configuration.cookieDomain) else {
      if Self.isAPI(request) { throw QuarkError.invalidResponse }
      return
    }
    do { try Self.check(response, request: request) } catch QuarkError.loginRequired {
      try invalidate(sent: sent)
      throw QuarkError.loginRequired
    }
    let refreshed = sent.merging(
      response, from: url, cookieDomain: configuration.cookieDomain)
    guard refreshed.valid else {
      try invalidate(sent: sent)
      throw QuarkError.loginRequired
    }
    if refreshed.header != sent.header, try storedCookie()?.header == sent.header {
      try secrets.write(Data(refreshed.header.utf8), for: secretKey)
    }
  }
  private func invalidate(sent: QuarkCookie) throws {
    guard try storedCookie()?.header == sent.header else { return }
    try secrets.delete(secretKey)
    notifyInvalidation()
  }
  private func notifyInvalidation() {
    guard !didNotifyInvalidation else { return }
    didNotifyInvalidation = true
    NotificationCenter.default.post(
      name: Self.loginInvalidatedNotification, object: nil,
      userInfo: ["secretKey": secretKey])
  }
  fileprivate static func trusted(_ url: URL?, domain: String) -> Bool {
    guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == domain || host.hasSuffix("." + domain)
  }
  private static func isAPI(_ request: URLRequest) -> Bool {
    request.url?.path.hasPrefix("/1/clouddrive/") == true || request.url?.path == "/account/info"
  }
  private static func prepare(
    _ original: URLRequest, cookie: QuarkCookie, configuration: QuarkCloudConfiguration
  ) -> URLRequest {
    var request = original
    if trusted(request.url, domain: configuration.cookieDomain) {
      request.setValue(cookie.header, forHTTPHeaderField: "Cookie")
      request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue(configuration.refererURL, forHTTPHeaderField: "Referer")
      if isAPI(request) {
        request.timeoutInterval = 30
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
      }
    } else {
      request.setValue(nil, forHTTPHeaderField: "Cookie")
    }
    return request
  }
  private static func check(_ response: HTTPResponse, request: URLRequest) throws {
    guard isAPI(request) else { return }
    if response.status == 401 { throw QuarkError.loginRequired }
    let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    if (object?["status"] as? NSNumber)?.intValue == 401
      || (object?["code"] as? NSNumber)?.intValue == 31001
    {
      throw QuarkError.loginRequired
    }
    if (200..<300).contains(response.status), request.url?.path == "/account/info",
      object?["success"] as? Bool == false
    {
      throw QuarkError.loginRequired
    }
  }
  private static func accountRequest(_ configuration: QuarkCloudConfiguration) -> URLRequest {
    var request = URLRequest(url: configuration.accountURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    return request
  }
  private static func spaceRequest(_ configuration: QuarkCloudConfiguration) -> URLRequest {
    var request = URLRequest(
      url: URL(
        string:
          configuration.apiBase
          + "/member?pr=\(configuration.clientParameter)&fr=pc&fetch_subscribe=false&_ch=home&fetch_identity=false"
      )!)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    return request
  }
  private static func identity(_ response: HTTPResponse) throws -> (String, String) {
    guard (200..<300).contains(response.status),
      let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      object["success"] as? Bool == true, let data = object["data"] as? [String: Any],
      let nickname = data["nickname"] as? String
    else { throw QuarkError.invalidResponse }
    let userID = data["uid"] as? String ?? ""
    return (userID, nickname)
  }
  private struct SpaceReply: Decodable {
    struct Value: Decodable {
      let total_capacity: Int64
      let use_capacity: Int64
    }
    let status: Int
    let code: Int
    let data: Value
  }
  private static func space(_ response: HTTPResponse) throws -> (Int64, Int64) {
    guard (200..<300).contains(response.status),
      let parsed = try? JSONDecoder().decode(SpaceReply.self, from: response.body),
      parsed.status == 200, parsed.code == 0, parsed.data.total_capacity >= 0,
      parsed.data.use_capacity >= 0, parsed.data.use_capacity <= parsed.data.total_capacity
    else { throw QuarkError.invalidResponse }
    return (parsed.data.total_capacity, parsed.data.use_capacity)
  }
}
