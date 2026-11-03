import Foundation

public struct HTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data
  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
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
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
  }
  public init(session: URLSession) { self.session = session }
  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    let (data, response) = try await session.data(for: request)
    return try Self.response(response, data: data)
  }
  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    var request = request
    request.timeoutInterval = 60
    let session = session
    let (bytes, response) = try await withThrowingTaskGroup(
      of: (URLSession.AsyncBytes, URLResponse).self
    ) { group in
      group.addTask { [request] in try await session.bytes(for: request) }
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
    return HTTPResponse(status: http.statusCode, headers: headers, body: data)
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
