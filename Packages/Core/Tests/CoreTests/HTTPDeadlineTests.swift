import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private final class HTTPFixtureControl: Sendable {
  let started = TestEvent()
  let stopped = TestEvent()
  let chunks = AsyncStream<(Data, TestEvent)>.makeStream()
}

private final class SlowHTTPFixture: URLProtocol, @unchecked Sendable {
  static let controls = Mutex<[String: HTTPFixtureControl]>([:])
  private let workTask = Mutex<Task<Void, Never>?>(nil)
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix(".invalid") == true
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let control = Self.controls.withLock({ $0[url.host ?? ""] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let work = Task { @Sendable [self] in
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      control.started.signal()
      for await (data, delivered) in control.chunks.stream {
        if Task.isCancelled { return }
        self.client?.urlProtocol(self, didLoad: data)
        delivered.signal()
      }
    }
    workTask.withLock { $0 = work }
  }
  override func stopLoading() {
    workTask.withLock {
      $0?.cancel()
      $0 = nil
    }
    Self.controls.withLock { $0[request.url?.host ?? ""] }?.stopped.signal()
  }
}

@Test func metadataDeadlineEndsEvenWhileResponseMakesProgress() async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [SlowHTTPFixture.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let host = UUID().uuidString.lowercased() + ".invalid"
  let control = HTTPFixtureControl()
  SlowHTTPFixture.controls.withLock { $0[host] = control }
  defer {
    control.chunks.continuation.finish()
    _ = SlowHTTPFixture.controls.withLock { $0.removeValue(forKey: host) }
  }
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(interval: .seconds(30), clock: clock.deadlineClock)
  let transport = URLSessionHTTPTransport(session: session)
  let operation = Task {
    try await transport.perform(
      URLRequest(url: URL(string: "https://" + host)!), deadline: deadline, upload: false)
  }
  defer { operation.cancel() }
  try await control.started.wait()
  await clock.waitForSleepRequests(1)
  for _ in 0..<2 {
    let delivered = TestEvent()
    control.chunks.continuation.yield((Data([1]), delivered))
    try await delivered.wait()
    clock.advance(by: .seconds(15))
  }
  do {
    _ = try await operation.value
    Issue.record("持续少量响应不应延长元数据请求总时限")
  } catch let error as URLError { #expect(error.code == .timedOut) }
  try await control.stopped.wait()
}

@Test func uploadProgressExtendsIdleDeadlineButLateProgressDoesNotReviveIt() async throws {
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(interval: .seconds(60), clock: clock.deadlineClock)
  let timedOut = TestEvent()
  let waiter = Task {
    do { try await deadline.wait() } catch let error as URLError {
      #expect(error.code == .timedOut)
      timedOut.signal()
    }
  }
  defer { waiter.cancel() }
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  deadline.recordProgress()
  clock.advance(by: .seconds(30))
  await clock.waitForSleepRequests(2)
  #expect(!timedOut.isSignaled)
  clock.advance(by: .seconds(29))
  deadline.recordProgress()
  clock.advance(by: .seconds(60))
  deadline.recordProgress()
  try await waiter.value
  #expect(timedOut.isSignaled)
  await #expect(throws: URLError.self) { try await deadline.wait() }
}

@Test func cancelledProgressDeadlineReleasesClockAndOperationWaiters() async throws {
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(interval: .seconds(60), clock: clock.deadlineClock)
  let entered = TestEvent()
  let operation = TestEvent()
  let running = Task {
    try await deadline.run {
      entered.signal()
      try await operation.wait()
    }
  }
  try await entered.wait()
  await clock.waitForSleepRequests(1)
  running.cancel()
  await #expect(throws: CancellationError.self) { try await running.value }
  #expect(clock.pendingSleepCount == 0)
}

@Test func accountQueueDeadlineDoesNotLoseOrStealAllowance() async throws {
  let clock = ManualTestClock()
  let limit = HTTPConcurrencyLimit(clock: clock.deadlineClock)
  for _ in 0..<4 { try await limit.acquire() }
  let queued = TestEvent()
  await limit.observeQueue { if $0 == 1 { queued.signal() } }
  let fifth = Task { try await limit.acquire() }
  defer { fifth.cancel() }
  try await queued.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  await #expect(throws: URLError.self) { try await fifth.value }
  for _ in 0..<4 { await limit.release() }
  for _ in 0..<4 { try await limit.acquire() }
  for _ in 0..<4 { await limit.release() }
}
