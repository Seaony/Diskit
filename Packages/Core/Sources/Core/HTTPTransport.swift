import Foundation

public struct HTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data
  public let url: URL?
  public init(status: Int, headers: [String: String] = [:], body: Data = Data(), url: URL? = nil) {
    self.url = url
    self.status = status
    self.headers = headers
    self.body = body
  }
  public func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

public struct HTTPStreamResponse: Sendable {
  public let response: HTTPResponse
  public let body: AsyncThrowingStream<Data, Error>
  public init(response: HTTPResponse, body: AsyncThrowingStream<Data, Error>) {
    self.response = response
    self.body = body
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
  func upload(_ request: URLRequest) async throws -> HTTPResponse
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

extension HTTPTransport {
  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    var request = request
    request.timeoutInterval = RemoteTimeout.transferIdle
    return try await send(request)
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    let response = try await send(request)
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream { continuation in
        if !response.body.isEmpty { continuation.yield(response.body) }
        continuation.finish()
      })
  }
}

public final class URLSessionHTTPTransport: HTTPTransport {
  private let session: URLSession
  private let redirectDelegate: HTTPRedirectDelegate
  public init(cookieDomain: String? = nil) {
    redirectDelegate = HTTPRedirectDelegate(cookieDomain: cookieDomain)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = RemoteTimeout.cloudRequest
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
  }
  public init(session: URLSession, cookieDomain: String? = nil) {
    self.session = session
    redirectDelegate = HTTPRedirectDelegate(cookieDomain: cookieDomain)
  }
  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    try await perform(
      request, deadline: HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest)),
      upload: false)
  }
  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    try await perform(
      request, deadline: HTTPProgressDeadline(interval: .seconds(RemoteTimeout.transferIdle)),
      upload: true)
  }
  func perform(
    _ original: URLRequest, deadline: HTTPProgressDeadline, upload: Bool
  ) async throws -> HTTPResponse {
    var request = original
    request.timeoutInterval = upload ? RemoteTimeout.transferIdle : RemoteTimeout.cloudRequest
    let session = session
    let delegate = upload
      ? HTTPRedirectDelegate(cookieDomain: redirectDelegate.cookieDomain, progress: { deadline.recordProgress() })
      : redirectDelegate
    return try await deadline.run { [request] in
      let (data, response) = try await session.data(for: request, delegate: delegate)
      return try Self.response(response, data: data)
    }
  }
  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    try await stream(request, clock: .continuous)
  }
  func stream(_ original: URLRequest, clock: DeadlineClock) async throws -> HTTPStreamResponse {
    var request = original
    request.timeoutInterval = RemoteTimeout.transferIdle
    let stream = HTTPDataStream(clock: clock)
    stream.start(session: session, request: request, cookieDomain: redirectDelegate.cookieDomain)
    let response = try await stream.response()
    return HTTPStreamResponse(response: response, body: AsyncThrowingStream(unfolding: { try await stream.next() }))
  }
  static func response(_ response: URLResponse, data: Data) throws -> HTTPResponse {
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: data, url: http.url)
  }
}

// 跳转不能扩大登录凭据或请求正文的发送范围。
enum HTTPRedirectPolicy {
  static func request(
    _ request: URLRequest, from source: URL, originalMethod: String, cookieDomain: String?
  ) -> URLRequest? {
    guard let destination = request.url, destination.scheme?.lowercased() == "https" else {
      return nil
    }
    let sameOrigin =
      source.scheme?.lowercased() == destination.scheme?.lowercased()
      && source.host?.lowercased() == destination.host?.lowercased()
      && (source.port ?? 443) == (destination.port ?? 443)
    if sameOrigin { return request }
    guard ["GET", "HEAD"].contains(originalMethod.uppercased()) else { return nil }
    var result = request
    let credentialHeaders = [
      "Authorization", "Proxy-Authorization", "SessionKey", "Signature",
      "Space-Authorization", "mcloud-sign", "x-captcha-token",
    ]
    for name in credentialHeaders {
      result.setValue(nil, forHTTPHeaderField: name)
    }
    func allowed(_ url: URL) -> Bool {
      guard let cookieDomain, let host = url.host?.lowercased() else { return false }
      return host == cookieDomain || host.hasSuffix("." + cookieDomain)
    }
    if !allowed(source) || !allowed(destination) {
      result.setValue(nil, forHTTPHeaderField: "Cookie")
    }
    return result
  }
}

private final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let cookieDomain: String?
  private let progress: (@Sendable () -> Void)?
  init(cookieDomain: String?, progress: (@Sendable () -> Void)? = nil) {
    self.cookieDomain = cookieDomain
    self.progress = progress
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    if bytesSent > 0 { progress?() }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let source = response.url else {
      completionHandler(nil)
      return
    }
    completionHandler(
      HTTPRedirectPolicy.request(
        request, from: source, originalMethod: task.originalRequest?.httpMethod ?? "GET",
        cookieDomain: cookieDomain))
  }
}
