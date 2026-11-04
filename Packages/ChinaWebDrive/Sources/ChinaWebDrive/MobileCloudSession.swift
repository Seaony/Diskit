import Core
import Foundation

public struct MobileCloudCredentials: Sendable, Equatable {
  public let phone: String
  public let token: String
  public let userDomainID: String?

  public init(phone: String, token: String, userDomainID: String? = nil) {
    self.phone = phone
    self.token = token
    self.userDomainID = userDomainID
  }
}

public enum MobileCloudError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidCredentials
  case invalidResponse
  case loginRequired

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    self == .invalidResponse ? Int(EIO) : Int(EACCES)
  }
  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: L("移动云盘登录信息不完整")
    case .invalidResponse: L("移动云盘返回了无法识别的数据")
    case .loginRequired: L("移动云盘登录已失效，请重新登录")
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

public struct MobileCloudRoute: Sendable, Equatable {
  public let personalBaseURL: URL
  public let hashAlgorithm: String
  public init(personalBaseURL: URL, hashAlgorithm: String = "sha256") {
    self.personalBaseURL = personalBaseURL
    self.hashAlgorithm = hashAlgorithm
  }
}

public actor MobileCloudSession {
  public typealias Refresh =
    @Sendable (MobileCloudCredentials) async throws
    -> MobileCloudCredentials

  public static let routeURL = URL(
    string: "https://user-njs.yun.139.com/user/route/qryRoutePolicy")!
  public static let userBaseURL = URL(string: "https://user-njs.yun.139.com/user")!
  public static let loginURL = URL(string: "https://yun.139.com/w/")!

  private var credentials: MobileCloudCredentials
  private let refresh: Refresh?
  let transport: any HTTPTransport
  private let now: @Sendable () -> Date
  private let nonce: @Sendable () -> String
  private var route: MobileCloudRoute?

  public init(
    credentials: MobileCloudCredentials,
    refresh: Refresh? = nil,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.init(
      credentials: credentials, refresh: refresh, transport: transport, now: Date.init,
      nonce: ChinaWebSupport.randomNonce)
  }

  init(
    credentials: MobileCloudCredentials, refresh: Refresh? = nil,
    transport: any HTTPTransport, now: @escaping @Sendable () -> Date,
    nonce: @escaping @Sendable () -> String
  ) {
    self.credentials = credentials
    self.refresh = refresh
    self.transport = DiagnosticHTTPTransport(
      POSIXHTTPTransport(transport), category: .chinaWebDrive)
    self.now = now
    self.nonce = nonce
  }

  public func connect() async throws {
    guard !credentials.phone.isEmpty, !credentials.token.isEmpty else {
      throw MobileCloudError.invalidCredentials
    }
    route = try await loadRoute()
  }

  public var userDomainID: String? { credentials.userDomainID }
  public var hashAlgorithm: String { route?.hashAlgorithm ?? "sha256" }

  public func disconnect() {
    route = nil
  }

  public func request(_ endpoint: String, body: Any) async throws -> Data {
    guard let route else { throw MobileCloudError.invalidResponse }
    var current = credentials
    var didRefresh = false
    while true {
      let payload = try ChinaWebSupport.jsonData(body)
      var lastResponse: HTTPResponse?
      var lastError: Error?
      for url in candidateURLs(route.personalBaseURL, endpoint: endpoint) {
        let request = try makeRequest(
          url: url, body: payload, credentials: current, route: false)
        let response = try await transport.send(request)
        lastResponse = response
        do {
          try validate(response)
          return response.body
        } catch MobileCloudError.loginRequired {
          lastError = MobileCloudError.loginRequired
          break
        } catch {
          lastError = error
          if response.status == 404
            || message(in: response.body)?.lowercased().contains(
              "route not found") == true
          {
            continue
          }
          throw error
        }
      }
      if lastError is MobileCloudError, !didRefresh, refresh != nil {
        current = try await validateRefresh(current)
        credentials = current
        didRefresh = true
        continue
      }
      if let response = lastResponse {
        throw mapFailure(response)
      }
      throw lastError ?? MobileCloudError.invalidResponse
    }
  }

  public func accountRequest(_ endpoint: String, body: Any) async throws -> Data {
    var current = credentials
    var didRefresh = false
    while true {
      let payload = try ChinaWebSupport.jsonData(body)
      let url = Self.userBaseURL.appending(
        path: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
      let request = try makeRequest(
        url: url, body: payload, credentials: current, route: false)
      let response = try await transport.send(request)
      do {
        try validate(response)
        return response.body
      } catch MobileCloudError.loginRequired {
        guard !didRefresh, refresh != nil else { throw MobileCloudError.loginRequired }
        current = try await validateRefresh(current)
        credentials = current
        didRefresh = true
      } catch {
        throw error
      }
    }
  }

  public func unsignedDownload(
    _ url: URL, range: Range<Int64>?
  ) async throws -> HTTPStreamResponse {
    guard url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil,
      url.password == nil
    else { throw MobileCloudError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue(ChinaWebSupport.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://yun.139.com/", forHTTPHeaderField: "Referer")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    return try await transport.stream(request)
  }

  private func loadRoute() async throws -> MobileCloudRoute {
    let userInfo: [String: Any]
    if let userDomainID = credentials.userDomainID, !userDomainID.isEmpty {
      userInfo = ["userDomainId": userDomainID]
    } else {
      userInfo = ["userType": 1, "accountType": 1, "accountName": credentials.phone]
    }
    let body = ["userInfo": userInfo, "modAddrType": 1] as [String: Any]
    let payload = try ChinaWebSupport.jsonData(body)
    let request = try makeRequest(
      url: Self.routeURL, body: payload, credentials: credentials, route: true)
    var response = try await transport.send(request)
    if isUnauthorized(response), refresh != nil {
      credentials = try await validateRefresh(credentials)
      let retry = try makeRequest(
        url: Self.routeURL, body: payload, credentials: credentials, route: true)
      response = try await transport.send(retry)
    }
    try validate(response)
    guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let data = root["data"] as? [String: Any],
      let list = data["routePolicyList"] as? [[String: Any]]
    else { throw MobileCloudError.invalidResponse }
    let personal =
      list.first(where: { $0["modName"] as? String == "personal" })
      ?? list.first
    guard let host = (personal?["httpsUrl"] as? String).flatMap(URL.init(string:)),
      host.scheme == "https"
    else { throw MobileCloudError.invalidResponse }
    let hashAlgorithm = (personal?["hashName"] as? String)?.lowercased() ?? "sha256"
    guard ["md5", "sha1", "sha256"].contains(hashAlgorithm) else {
      throw MobileCloudError.invalidResponse
    }
    return MobileCloudRoute(personalBaseURL: host, hashAlgorithm: hashAlgorithm)
  }

  private func validateRefresh(
    _ rejected: MobileCloudCredentials
  ) async throws -> MobileCloudCredentials {
    guard let refresh else { throw MobileCloudError.loginRequired }
    let value: MobileCloudCredentials
    do {
      value = try await refresh(rejected)
    } catch {
      throw MobileCloudError.loginRequired
    }
    guard !value.phone.isEmpty, !value.token.isEmpty else {
      throw MobileCloudError.loginRequired
    }
    return value
  }

  private func makeRequest(
    url: URL, body: Data, credentials: MobileCloudCredentials, route: Bool
  ) throws -> URLRequest {
    guard url.scheme == "https", let host = url.host else {
      throw MobileCloudError.invalidResponse
    }
    let timestamp = ChinaWebSupport.dateTimestamp(
      now: now(), timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!)
    let random = nonce()
    guard random.utf8.count == 16 else { throw MobileCloudError.invalidResponse }
    let signature = Self.sign(body: body, timestamp: timestamp, random: random)
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue(ChinaWebSupport.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    request.setValue("https://yun.139.com", forHTTPHeaderField: "Origin")
    request.setValue("https://yun.139.com/w/", forHTTPHeaderField: "Referer")
    request.setValue("Basic \(credentials.token)", forHTTPHeaderField: "Authorization")
    request.setValue("\(timestamp),\(random),\(signature)", forHTTPHeaderField: "mcloud-sign")
    request.setValue(
      "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||",
      forHTTPHeaderField: "x-DeviceInfo")
    request.setValue("default", forHTTPHeaderField: "CMS-DEVICE")
    request.setValue("10000034", forHTTPHeaderField: "x-huawei-channelSrc")
    request.setValue("2", forHTTPHeaderField: "x-inner-ntwk")
    request.setValue("PC", forHTTPHeaderField: "x-m4c-caller")
    request.setValue("10002", forHTTPHeaderField: "x-m4c-src")
    request.setValue("1", forHTTPHeaderField: "Inner-Hcy-Router-Https")
    request.setValue("1", forHTTPHeaderField: "x-SvcType")
    request.setValue("1000101", forHTTPHeaderField: "mcloud-channel")
    request.setValue("10701", forHTTPHeaderField: "mcloud-client")
    request.setValue("7.14.0", forHTTPHeaderField: "mcloud-version")
    if !route {
      request.setValue("web", forHTTPHeaderField: "Caller")
      request.setValue("001", forHTTPHeaderField: "mcloud-route")
      request.setValue("v1", forHTTPHeaderField: "x-yun-api-version")
      request.setValue("10000034", forHTTPHeaderField: "x-yun-app-channel")
      request.setValue("10000034", forHTTPHeaderField: "x-yun-channel-source")
      request.setValue(
        "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||",
        forHTTPHeaderField: "x-yun-client-info")
      request.setValue("100", forHTTPHeaderField: "x-yun-module-type")
      request.setValue("1", forHTTPHeaderField: "x-yun-svc-type")
    }
    guard ChinaWebSupport.trustedHost(host, domain: "yun.139.com"),
      ChinaWebSupport.trustedHost(host, domain: "139.com") || host.hasSuffix(".139.com")
    else { throw MobileCloudError.invalidResponse }
    return request
  }

  private func candidateURLs(_ base: URL, endpoint: String) -> [URL] {
    guard var normal = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return [] }
    normal.path = normal.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    normal.path =
      "/" + normal.path + (normal.path == "/" ? "" : "/")
      + endpoint
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let trimmed = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let withoutHCY =
      trimmed.replacingOccurrences(
        of: #"/hcy(?:/orchestration)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
    var fallback = URLComponents(string: withoutHCY) ?? normal
    fallback.path =
      (fallback.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        .isEmpty
      ? "/orchestration/" + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      : "/" + fallback.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        + "/orchestration/"
        + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return [normal.url, fallback.url].compactMap { $0 }.reduce(into: [URL]()) {
      if !$0.contains($1) { $0.append($1) }
    }
  }

  private func validate(_ response: HTTPResponse) throws {
    if isUnauthorized(response) { throw MobileCloudError.loginRequired }
    guard (200..<300).contains(response.status) else {
      throw RemoteError.http(response.status)
    }
    guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { throw MobileCloudError.invalidResponse }
    if root["success"] as? Bool == false { throw mapFailure(response) }
    let code = (root["code"] as? NSNumber)?.intValue
    let codeText = root["code"] as? String
    if code == 9008 || code == 9100 || codeText == "9008" || codeText == "9100" {
      throw MobileCloudError.loginRequired
    }
    if code == 9000 || codeText == "9000" {
      throw mapFailure(response)
    }
  }

  private func isUnauthorized(_ response: HTTPResponse) -> Bool {
    if response.status == 401 || response.status == 403 { return true }
    guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { return false }
    let code = (root["code"] as? NSNumber)?.intValue
    let text = root["code"] as? String
    return code == 9008 || code == 9100 || text == "9008" || text == "9100"
  }

  private func mapFailure(_ response: HTTPResponse) -> RemoteError {
    if isUnauthorized(response) { return .unauthorized }
    guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { return .http(response.status) }
    let code =
      (root["code"] as? NSNumber)?.intValue
      ?? (root["code"] as? String).flatMap(Int.init)
    let message =
      root["message"] as? String ?? root["msg"] as? String ?? root["error_msg"] as? String
    return ChinaWebSupport.mapBusiness(code: code ?? response.status, message: message)
  }

  private func message(in body: Data) -> String? {
    let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    return root?["message"] as? String ?? root?["msg"] as? String
  }

  static func sign(body: Data, timestamp: String, random: String) -> String {
    guard let text = String(data: body, encoding: .utf8) else { return "" }
    let encoded = ChinaWebSupport.percentEncodeJavaScript(text)
    let sorted = String(encoded.sorted())
    let base64 = Data(sorted.utf8).base64EncodedString()
    let first = ChinaWebSupport.md5Hex(base64)
    let second = ChinaWebSupport.md5Hex(timestamp + ":" + random)
    return ChinaWebSupport.md5Hex(first + second).uppercased()
  }
}
