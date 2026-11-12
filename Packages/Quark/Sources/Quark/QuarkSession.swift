import Core
import Foundation

public actor QuarkSession {
  public static let loginInvalidatedNotification = Notification.Name(
    "com.seaony.Diskit.quarkLoginInvalidated")
  public static let userAgent = QuarkCloudConfiguration.quark.userAgent
  public nonisolated let configuration: QuarkCloudConfiguration
  private let secretKey: String
  private let secrets: any SecretStore
  private let transport: any HTTPTransport
  private var didNotifyInvalidation = false
  public init(
    secretKey: String, secrets: any SecretStore = RuntimeStorage.current.secrets,
    configuration: QuarkCloudConfiguration = .quark,
    transport: (any HTTPTransport)? = nil
  ) {
    self.secretKey = secretKey
    self.secrets = secrets
    self.configuration = configuration
    self.transport = DiagnosticHTTPTransport(
      transport ?? URLSessionHTTPTransport(cookieDomain: configuration.cookieDomain),
      category: .quark)
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

  public func authorized(_ original: URLRequest, upload: Bool = false) async throws -> HTTPResponse
  {
    let cookie = try requireCookie()
    let request = Self.prepare(original, cookie: cookie, configuration: configuration)
    let response = try await (upload ? transport.upload(request) : transport.send(request))
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
    guard (200..<300).contains(response.status) else { return }
    let refreshed = sent.merging(
      response, from: url, cookieDomain: configuration.cookieDomain)
    guard refreshed.valid else {
      try invalidate(sent: sent)
      throw QuarkError.loginRequired
    }
    if refreshed.header != sent.header, try storedCookie()?.header == sent.header {
      try secrets.write(Data(refreshed.header.utf8), for: secretKey)
    }
    didNotifyInvalidation = false
  }
  private func invalidate(sent: QuarkCookie) throws {
    guard try storedCookie()?.header == sent.header else { return }
    notifyInvalidation()
  }
  private func notifyInvalidation() {
    guard !didNotifyInvalidation else { return }
    didNotifyInvalidation = true
    NotificationCenter.default.post(
      name: Self.loginInvalidatedNotification, object: nil,
      userInfo: ["secretKey": secretKey])
  }
  static func trusted(_ url: URL?, domain: String) -> Bool {
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
        request.timeoutInterval = RemoteTimeout.cloudRequest
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
      }
    } else {
      request.setValue(nil, forHTTPHeaderField: "Cookie")
    }
    return request
  }
  private static func check(_ response: HTTPResponse, request: URLRequest) throws {
    do {
      guard isAPI(request) else { return }
      if response.status == 401 { throw QuarkError.loginRequired }
      guard response.status != 429, response.status < 500 else { return }
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
    } catch {
      if (200..<300).contains(response.status) {
        PackageDiagnostics.failure(error, category: .quark, operation: .request)
      }
      throw error
    }
  }
  private static func accountRequest(_ configuration: QuarkCloudConfiguration) -> URLRequest {
    var request = URLRequest(url: configuration.accountURL)
    request.httpMethod = "GET"
    request.timeoutInterval = RemoteTimeout.cloudRequest
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
    request.timeoutInterval = RemoteTimeout.cloudRequest
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
