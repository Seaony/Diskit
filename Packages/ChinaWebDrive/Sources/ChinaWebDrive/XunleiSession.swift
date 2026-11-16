import Core
import Foundation

public struct XunleiCredentials: Sendable, Equatable {
  public let accessToken: String
  public let spaceAuthorization: String?
  public init(accessToken: String, spaceAuthorization: String? = nil) {
    self.accessToken = accessToken
    self.spaceAuthorization = spaceAuthorization
  }
}

public enum XunleiError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case invalidCredentials
  case invalidResponse
  case loginRequired
  case unsupportedUploadProvider
  case verificationRequired

  public var requiresLogin: Bool { self == .loginRequired }

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    switch self {
    case .invalidResponse: Int(EIO)
    case .unsupportedUploadProvider: Int(ENOTSUP)
    case .verificationRequired: Int(EAGAIN)
    case .invalidCredentials, .loginRequired: Int(EACCES)
    }
  }
  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: L("迅雷云盘登录信息不完整")
    case .invalidResponse: L("迅雷云盘返回了无法识别的数据")
    case .loginRequired: L("迅雷云盘登录已失效，请重新登录")
    case .unsupportedUploadProvider: L("迅雷返回了不支持的上传服务")
    case .verificationRequired: L("请先在网页完成验证后重试")
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

public actor XunleiSession {
  public typealias Refresh = @Sendable (XunleiCredentials) async throws -> XunleiCredentials

  public static let apiBase = URL(string: "https://api-pan.xunlei.com/drive/v1")!

  private var credentials: XunleiCredentials
  private let refresh: Refresh?
  private let transport: any HTTPTransport
  private var refreshing: Task<XunleiCredentials, Error>?

  public init(
    credentials: XunleiCredentials,
    refresh: Refresh? = nil,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.credentials = credentials
    self.refresh = refresh
    self.transport = DiagnosticHTTPTransport(
      POSIXHTTPTransport(transport), category: .chinaWebDrive)
  }

  public func connect() async throws {
    guard !credentials.accessToken.isEmpty else { throw XunleiError.invalidCredentials }
    _ = try await request(method: "GET", path: "about")
  }

  public func request(
    method: String, path: String, query: [URLQueryItem] = [], json: Any? = nil
  ) async throws -> HTTPResponse {
    try await request(
      method: method, url: makeURL(path: path, query: query), json: json)
  }

  public func request(
    method: String, url: URL, json: Any? = nil
  ) async throws -> HTTPResponse {
    guard url.scheme == "https",
      let host = url.host,
      ChinaWebSupport.trustedHost(host, domain: "xunlei.com")
    else { throw XunleiError.invalidResponse }
    var current = credentials
    var didRefresh = false
    while true {
      var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
      request.httpMethod = method
      request.setValue("Token \(current.accessToken)", forHTTPHeaderField: "Authorization")
      if let space = current.spaceAuthorization, !space.isEmpty {
        request.setValue(space, forHTTPHeaderField: "Space-Authorization")
      }
      request.setValue(ChinaWebSupport.userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue("https://pan.xunlei.com/", forHTTPHeaderField: "Origin")
      request.setValue("https://pan.xunlei.com/", forHTTPHeaderField: "Referer")
      if let json {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ChinaWebSupport.jsonData(json)
      }
      let response = try await transport.send(request)
      if ChinaWebSupport.requiresVerification(response) { throw XunleiError.verificationRequired }
      if Self.isUnauthorized(response), !didRefresh, refresh != nil {
        current = try await refreshed(current)
        didRefresh = true
        continue
      }
      if Self.isUnauthorized(response) { throw XunleiError.loginRequired }
      try ChinaWebSupport.checkHTTP(response)
      if let error = Self.businessError(response.body) {
        PackageDiagnostics.failure(error, category: .chinaWebDrive, operation: .request)
        throw error
      }
      return response
    }
  }

  public func download(_ url: URL, range: Range<Int64>?) async throws -> HTTPStreamResponse {
    guard url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil,
      url.password == nil
    else { throw XunleiError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
    request.setValue(ChinaWebSupport.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://pan.xunlei.com/", forHTTPHeaderField: "Referer")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    return try await transport.stream(request)
  }

  private func makeURL(path: String, query: [URLQueryItem]) -> URL {
    var components = URLComponents(
      url: Self.apiBase.appending(
        path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
      resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    return components.url!
  }

  private func refreshed(_ rejected: XunleiCredentials) async throws -> XunleiCredentials {
    if credentials != rejected { return credentials }
    if let refreshing { return try await refreshing.value }
    guard let refresh else { throw XunleiError.loginRequired }
    let task = Task<XunleiCredentials, Error> {
      let value: XunleiCredentials
      do {
        value = try await HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest)).run {
          try await refresh(rejected)
        }
      } catch { throw NetworkFailure.posix(error) }
      guard !value.accessToken.isEmpty else { throw XunleiError.loginRequired }
      return value
    }
    refreshing = task
    defer { refreshing = nil }
    let value = try await task.value
    credentials = value
    return value
  }

  private static func isUnauthorized(_ response: HTTPResponse) -> Bool {
    if response.status == 429 || response.status >= 500 { return false }
    if ChinaWebSupport.requiresVerification(response) { return false }
    if response.status == 401 { return true }
    let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    let text = ["error", "error_description", "message", "msg"].compactMap {
      object?[$0] as? String
    }.joined(separator: " ").lowercased()
    let code =
      object?["error_code"] as? Int ?? object?["code"] as? Int
      ?? Int(object?["error_code"] as? String ?? object?["code"] as? String ?? "")
    return object?["error"] as? String == "invalid_token" || text.contains("token expired")
      || text.contains("unauthorized") || text.contains("login plz") || code == 1001
      || code == 1002
  }

  private static func businessError(_ body: Data) -> RemoteError? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let error = object["error"] as? String
    else { return nil }
    let value = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return nil }
    if value.contains("space") || value.contains("not_enough") {
      return .posix(ENOSPC)
    }
    // 先认「不存在」：file_not_exist 里也含 exist，后判断会被当成已存在
    if value.contains("not_found") || value.contains("not found") || value.contains("not_exist")
      || value.contains("not exist")
    {
      return .posix(ENOENT)
    }
    if value.contains("exist") || value.contains("conflict") || value.contains("duplicate") {
      return .posix(EEXIST)
    }
    if value.contains("too_many") || value.contains("too many") {
      return .rateLimited
    }
    if value.contains("not_allowed") || value.contains("not allowed")
      || value.contains("shield")
    {
      return .posix(EACCES)
    }
    if value.contains("params") || value.contains("invalid") {
      return .posix(EINVAL)
    }
    return .posix(EIO)
  }
}
