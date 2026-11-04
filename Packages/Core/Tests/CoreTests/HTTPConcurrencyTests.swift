import CoreTestSupport
import Foundation
import Testing

@testable import Core

private actor LimitedTransportProbe: HTTPTransport {
  var calls = 0
  let failure: Bool
  init(failure: Bool = false) { self.failure = failure }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    calls += 1
    if failure { throw URLError(.notConnectedToInternet) }
    return HTTPResponse(status: 200)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    calls += 1
    return HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream {
        if failure {
          $0.finish(throwing: URLError(.networkConnectionLost))
        } else {
          $0.yield(Data([1]))
          $0.finish()
        }
      })
  }
}

@Test func sharedHTTPAllowanceHasAccountIdentityAndReleasesUnusedEntries() {
  let key = UUID().uuidString
  var first: HTTPConcurrencyLimit? = .shared(for: key)
  #expect(first === HTTPConcurrencyLimit.shared(for: key))
  #expect(first !== HTTPConcurrencyLimit.shared(for: key + "other"))
  weak let released = first
  first = nil
  #expect(released == nil)
}

@Test func cancelledHTTPWaiterDoesNotConsumeAllowance() async throws {
  let limit = HTTPConcurrencyLimit(clock: ManualTestClock().deadlineClock)
  for _ in 0..<4 { try await limit.acquire() }
  let queued = TestEvent()
  await limit.observeQueue { if $0 == 1 { queued.signal() } }
  let waiter = Task {
    try await limit.acquire()
    await limit.release()
  }
  try await queued.wait()
  waiter.cancel()
  await #expect(throws: CancellationError.self) { try await waiter.value }
  for _ in 0..<4 { await limit.release() }
  let probe = LimitedTransportProbe()
  let transport = LimitedHTTPTransport(probe, limit: limit)
  for _ in 0..<8 {
    _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid")!))
  }
  #expect(await probe.calls == 8)
}

@Test(arguments: [false, true])
func httpAllowanceSurvivesResponseAndStreamErrors(stream: Bool) async throws {
  let probe = LimitedTransportProbe(failure: true)
  let transport = LimitedHTTPTransport(
    probe, limit: HTTPConcurrencyLimit(clock: ManualTestClock().deadlineClock))
  let request = URLRequest(url: URL(string: "https://example.invalid")!)
  for _ in 0..<8 {
    await #expect(throws: URLError.self) {
      if stream {
        let response = try await transport.stream(request)
        for try await _ in response.body {}
      } else {
        _ = try await transport.send(request)
      }
    }
  }
  #expect(await probe.calls == 8)
}

@Test(arguments: [false, true])
func httpStreamHoldsAllowanceUntilFinishedOrDiscarded(discard: Bool) async throws {
  let probe = LimitedTransportProbe()
  let limit = HTTPConcurrencyLimit(clock: ManualTestClock().deadlineClock)
  let queued = TestEvent()
  await limit.observeQueue { if $0 == 1 { queued.signal() } }
  let transport = LimitedHTTPTransport(probe, limit: limit)
  let request = URLRequest(url: URL(string: "https://example.invalid")!)
  var responses: [HTTPStreamResponse] = []
  for _ in 0..<4 { responses.append(try await transport.stream(request)) }
  let fifth = Task { try await transport.send(request) }
  defer { fifth.cancel() }
  try await queued.wait()
  #expect(await probe.calls == 4)
  if discard {
    responses.removeLast()
  } else {
    for try await _ in responses[0].body {}
  }
  #expect(try await fifth.value.status == 200)
  #expect(await probe.calls == 5)
}
