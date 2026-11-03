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
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

extension HTTPTransport {
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

public struct URLSessionHTTPTransport: HTTPTransport {
  private let session: URLSession
  private let redirectDelegate: HTTPRedirectDelegate
  public init(cookieDomain: String? = nil) {
    redirectDelegate = HTTPRedirectDelegate(cookieDomain: cookieDomain)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
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
    let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
    return try Self.response(response, data: data)
  }
  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    var request = request
    request.timeoutInterval = 60
    let session = session
    let redirectDelegate = redirectDelegate
    let (bytes, response) = try await withThrowingTaskGroup(
      of: (URLSession.AsyncBytes, URLResponse).self
    ) { group in
      group.addTask { [request] in try await session.bytes(for: request, delegate: redirectDelegate)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw URLError(.cancelled) }
      return value
    }
    let metadata = try Self.response(response, data: Data())
    let cursor = HTTPByteCursor(bytes)
    return HTTPStreamResponse(
      response: metadata, body: AsyncThrowingStream(unfolding: { try await cursor.next() }))
  }
  private static func response(_ response: URLResponse, data: Data) throws -> HTTPResponse {
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: data, url: http.url)
  }
}

private actor HTTPByteCursor {
  private var iterator: URLSession.AsyncBytes.Iterator?
  private let task: URLSessionDataTask
  private var finished = false
  init(_ bytes: URLSession.AsyncBytes) {
    task = bytes.task
    iterator = bytes.makeAsyncIterator()
  }
  deinit { task.cancel() }
  func next() async throws -> Data? {
    if finished { return nil }
    guard var current = iterator else { throw URLError(.cannotLoadFromNetwork) }
    iterator = nil
    defer { if !finished { iterator = current } }
    do {
      try Task.checkCancellation()
      var chunk = Data()
      chunk.reserveCapacity(65_536)
      while chunk.count < 65_536 {
        guard let byte = try await current.next() else {
          finished = true
          break
        }
        chunk.append(byte)
      }
      return chunk.isEmpty ? nil : chunk
    } catch {
      finished = true
      task.cancel()
      throw error
    }
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
    result.setValue(nil, forHTTPHeaderField: "Authorization")
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
  init(cookieDomain: String?) { self.cookieDomain = cookieDomain }
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
