@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class StreamReleaseState: Sendable {
  let released = Mutex(false)
}

private final class StreamLifetime: Sendable {
  let state: StreamReleaseState
  init(_ state: StreamReleaseState) { self.state = state }
  deinit { state.released.withLock { $0 = true } }
}

private func retryDeadline(
  _ clock: ManualTestClock = ManualTestClock(), interval: Duration = .seconds(30)
) -> HTTPProgressDeadline {
  HTTPProgressDeadline(
    interval: interval,
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
}

private actor RetryProbe: HTTPTransport {
  var responses: [HTTPResponse]
  var requests: [URLRequest] = []
  let sleep: @Sendable () async throws -> Void
  let networkFailure: Bool
  let lifetimeState = StreamReleaseState()
  weak var previousBody: StreamLifetime?

  init(
    _ responses: [HTTPResponse], networkFailure: Bool = false,
    sleep: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.responses = responses
    self.sleep = sleep
    self.networkFailure = networkFailure
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    try await sleep()
    if networkFailure, requests.count == 1 { throw URLError(.networkConnectionLost) }
    guard !responses.isEmpty else { throw RemoteError.protocolError }
    return responses.removeFirst()
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse { try await send(request) }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    #expect(previousBody == nil)
    let response = try await send(request)
    let lifetime = StreamLifetime(lifetimeState)
    previousBody = lifetime
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream(unfolding: {
        _ = lifetime
        return nil
      }))
  }
}

@Test(arguments: [
  "insufficient_space", "storageQuotaExceeded", "rateLimitExceeded", "too_many_write_operations",
  "no_write_permission", "path/conflict",
])
func successfulCloudDataIsNotAnErrorBecauseOfItsFilename(_ name: String) async throws {
  let body = try JSONSerialization.data(withJSONObject: ["name": name, "data": ["message": name]])
  let response = HTTPResponse(status: 200, body: body)
  #expect(CloudDriveSupport.mapHTTP(response) == nil)
  let probe = RetryProbe([response])
  let actual = try await CloudDriveSupport.sendWithRetry(
    probe, URLRequest(url: URL(string: "https://example.invalid/read")!), deadline: retryDeadline())
  #expect(actual.body == body)
  #expect(await probe.requests.count == 1)
}

@Test(arguments: [429, 503, 504], [false, true])
func nonIdempotentCloudPostIsNeverAutomaticallyReplayed(status: Int, upload: Bool) async throws {
  let probe = RetryProbe([
    HTTPResponse(status: status, headers: ["Retry-After": "0"]), HTTPResponse(status: 200),
  ])
  var request = URLRequest(url: URL(string: "https://example.invalid/create")!)
  request.httpMethod = "POST"
  request.httpBody = Data("side-effect".utf8)
  let response = try await CloudDriveSupport.sendWithRetry(
    probe, request, upload: upload, deadline: retryDeadline(), sleep: { #expect($0 == .zero) })
  #expect(response.status == status)
  #expect(await probe.requests.count == 1)
}

@Test(arguments: [false, true])
func readRetriesHonorDeadlineIncludingBackoff(stream: Bool) async throws {
  let probe = RetryProbe([
    HTTPResponse(status: 503, headers: ["Retry-After": "1"]), HTTPResponse(status: 200),
  ])
  let request = URLRequest(url: URL(string: "https://example.invalid/read")!)
  let clock = ManualTestClock()
  let deadline = retryDeadline(clock, interval: .milliseconds(30))
  let operation = Task {
    do {
      if stream {
        _ = try await CloudDriveSupport.streamWithRetry(
          probe, request, deadline: deadline, sleep: { try await clock.sleep(for: $0) })
      } else {
        _ = try await CloudDriveSupport.sendWithRetry(
          probe, request, deadline: deadline, sleep: { try await clock.sleep(for: $0) })
      }
      Issue.record("退避必须包含在总时限内")
    } catch let error as URLError { #expect(error.code == .timedOut) }
  }
  await clock.waitForSleepRequests(2)
  clock.advance(by: .milliseconds(30))
  try await operation.value
  #expect(await probe.requests.count == 1)
  if stream { #expect(probe.lifetimeState.released.withLock { $0 }) }
}

@Test func repeatedReadRequestsShareOneDeadline() async throws {
  let clock = ManualTestClock()
  let probe = RetryProbe([
    HTTPResponse(status: 503, headers: ["Retry-After": "0"]), HTTPResponse(status: 200),
  ], sleep: { try await clock.sleep(for: .milliseconds(40)) })
  let deadline = retryDeadline(clock, interval: .milliseconds(60))
  let operation = Task {
    do {
      _ = try await CloudDriveSupport.sendWithRetry(
        probe, URLRequest(url: URL(string: "https://example.invalid/read")!),
        deadline: deadline, sleep: { try await clock.sleep(for: $0) })
      Issue.record("第二次请求不应获得新的完整时限")
    } catch let error as URLError { #expect(error.code == .timedOut) }
  }
  await clock.waitForSleepRequests(2)
  clock.advance(by: .milliseconds(40))
  // 总时限、首次请求、零退避和第二次请求均已注册。
  await clock.waitForSleepRequests(4)
  clock.advance(by: .milliseconds(20))
  try await operation.value
  #expect(await probe.requests.count == 2)
}

@Test func streamRetryReleasesRejectedBodyBeforeNextRequest() async throws {
  let probe = RetryProbe([
    HTTPResponse(status: 429, headers: ["Retry-After": "0"]), HTTPResponse(status: 200),
  ])
  let response = try await CloudDriveSupport.streamWithRetry(
    probe, URLRequest(url: URL(string: "https://example.invalid/read")!),
    deadline: retryDeadline(), sleep: { #expect($0 == .zero) })
  #expect(response.response.status == 200)
  #expect(await probe.requests.count == 2)
  #expect(probe.lifetimeState.released.withLock { $0 })
}

@Test func retryAfterBeyondBudgetIsNotShortened() async throws {
  let probe = RetryProbe([
    HTTPResponse(status: 429, headers: ["Retry-After": "120"]), HTTPResponse(status: 200),
  ])
  let response = try await CloudDriveSupport.sendWithRetry(
    probe, URLRequest(url: URL(string: "https://example.invalid/read")!),
    deadline: retryDeadline(ManualTestClock(), interval: .milliseconds(30)))
  #expect(response.status == 429)
  #expect(await probe.requests.count == 1)
  let now = Date(timeIntervalSince1970: 0)
  #expect(
    CloudDriveSupport.retryDelay(
      HTTPResponse(status: 429, headers: ["Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"]),
      attempt: 0, now: now) == 120)
}

@Test(arguments: [false, true])
func transientNetworkRetryIsLimitedToReplayableRequests(read: Bool) async throws {
  let probe = RetryProbe([HTTPResponse(status: 200)], networkFailure: true)
  var request = URLRequest(url: URL(string: "https://example.invalid/action")!)
  request.httpMethod = read ? "GET" : "POST"
  if read {
    let clock = ManualTestClock()
    let deadline = retryDeadline(clock, interval: .seconds(30))
    let operation = Task {
      try await CloudDriveSupport.sendWithRetry(
        probe, request, deadline: deadline, sleep: { try await clock.sleep(for: $0) })
    }
    await clock.waitForSleepRequests(2)
    clock.advance(by: .seconds(1))
    #expect(try await operation.value.status == 200)
    #expect(await probe.requests.count == 2)
  } else {
    await #expect(throws: URLError.self) {
      _ = try await CloudDriveSupport.sendWithRetry(probe, request, deadline: retryDeadline())
    }
    #expect(await probe.requests.count == 1)
  }
}

@Test func explicitNonReplayableGetIsNotRetried() async throws {
  let probe = RetryProbe([
    HTTPResponse(status: 503, headers: ["Retry-After": "0"]), HTTPResponse(status: 200),
  ])
  let response = try await CloudDriveSupport.sendWithRetry(
    probe, URLRequest(url: URL(string: "https://example.invalid/token")!), retrySafe: false,
    deadline: retryDeadline(), sleep: { #expect($0 == .zero) })
  #expect(response.status == 503)
  #expect(await probe.requests.count == 1)
}

@Test func uploadDoesNotAcquireMetadataTotalDeadline() async throws {
  let clock = ManualTestClock()
  let probe = RetryProbe(
    [HTTPResponse(status: 200)], sleep: { try await clock.sleep(for: .milliseconds(40)) })
  var request = URLRequest(url: URL(string: "https://example.invalid/upload")!)
  request.httpMethod = "PUT"
  let deadline = retryDeadline(clock, interval: .milliseconds(10))
  let operation = Task {
    try await CloudDriveSupport.sendWithRetry(
      probe, request, upload: true, deadline: deadline)
  }
  await clock.waitForSleepRequests(1)
  clock.advance(by: .milliseconds(40))
  #expect(try await operation.value.status == 200)
}
