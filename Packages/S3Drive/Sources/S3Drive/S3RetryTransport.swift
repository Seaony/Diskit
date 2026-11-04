import Core
import Foundation

// 只重试服务端明确限流的幂等请求，避免重复创建上传任务。
struct S3RetryTransport: HTTPTransport {
  let base: any HTTPTransport
  let sleep: @Sendable (Duration) async throws -> Void

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    try await perform(request, upload: false)
  }

  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    try await perform(request, upload: true)
  }

  private func perform(_ request: URLRequest, upload: Bool) async throws -> HTTPResponse {
    for attempt in 0...3 {
      try Task.checkCancellation()
      let response = try await (upload ? base.upload(request) : base.send(request))
      guard shouldRetry(request, response: response, attempt: attempt) else { return response }
      try await sleep(delay(response, attempt: attempt))
    }
    throw RemoteError.rateLimited
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    for attempt in 0...3 {
      try Task.checkCancellation()
      let stream = try await base.stream(request)
      guard shouldRetry(request, response: stream.response, attempt: attempt) else { return stream }
      try await sleep(delay(stream.response, attempt: attempt))
    }
    throw RemoteError.rateLimited
  }

  private func shouldRetry(_ request: URLRequest, response: HTTPResponse, attempt: Int) -> Bool {
    attempt < 3 && ["GET", "HEAD", "PUT", "DELETE"].contains(request.httpMethod ?? "GET")
      && [429, 503].contains(response.status)
  }

  private func delay(_ response: HTTPResponse, attempt: Int) -> Duration {
    let backoff = Double(1 << attempt)
    let retryAfter = response.header("Retry-After").flatMap(Double.init) ?? 0
    return .seconds(min(30, max(backoff, retryAfter.isFinite ? retryAfter : 0)))
  }
}
