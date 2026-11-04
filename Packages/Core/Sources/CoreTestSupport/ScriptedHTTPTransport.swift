import Core
import Foundation
import Synchronization

public final class ScriptedHTTPTransport: HTTPTransport, Sendable {
  public let responses = Mutex<[HTTPResponse]>([])
  public let requests = Mutex<[URLRequest]>([])
  public let uploadRequests = Mutex<[URLRequest]>([])
  public let streamResponse: HTTPResponse
  private let streamBody: Data

  public init(
    _ responses: [HTTPResponse] = [], streamResponse: HTTPResponse? = nil,
    streamBody: Data = Data("range".utf8)
  ) {
    self.responses.withLock { $0 = responses }
    self.streamResponse = streamResponse ?? HTTPResponse(status: 200)
    self.streamBody = streamBody
  }

  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    uploadRequests.withLock { $0.append(request) }
    return try await send(request)
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return responses.withLock {
      guard !$0.isEmpty else { return HTTPResponse(status: 500) }
      return $0.removeFirst()
    }
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.withLock { $0.append(request) }
    return HTTPStreamResponse(
      response: streamResponse,
      body: AsyncThrowingStream { continuation in
        continuation.yield(streamBody)
        continuation.finish()
      })
  }
}
