import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private final class BlockStreamFixture: URLProtocol, @unchecked Sendable {
  struct Control: Sendable {
    let started = TestEvent()
    let stopped = TestEvent()
  }
  static let controls = Mutex<[String: Control]>([:])
  override class func canInit(with request: URLRequest) -> Bool {
    controls.withLock { $0[request.url?.host ?? ""] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.controls.withLock { $0[request.url?.host ?? ""] }?.started.signal()
  }
  override func stopLoading() {
    Self.controls.withLock { $0[request.url?.host ?? ""] }?.stopped.signal()
  }
}

private func streamHeaders() -> HTTPURLResponse {
  HTTPURLResponse(url: URL(string: "https://blocks.invalid/file")!, statusCode: 429,
    httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "2"])!
}

private func withStartedStream(
  clock: ManualTestClock,
  _ operation: (HTTPDataStream, BlockStreamFixture.Control) async throws -> Void
) async throws {
  let host = UUID().uuidString.lowercased() + ".invalid"
  let control = BlockStreamFixture.Control()
  BlockStreamFixture.controls.withLock { $0[host] = control }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [BlockStreamFixture.self]
  let session = URLSession(configuration: configuration)
  defer {
    session.invalidateAndCancel()
    _ = BlockStreamFixture.controls.withLock { $0.removeValue(forKey: host) }
  }
  let stream = HTTPDataStream(clock: clock.deadlineClock)
  stream.start(session: session, request: URLRequest(url: URL(string: "https://" + host)!), cookieDomain: nil)
  try await control.started.wait()
  try await operation(stream, control)
  stream.cancel()
}

@Test func blockStreamPreservesQueuedBytesBeforeCompletionAndError() async throws {
  for fails in [false, true] {
    let stream = HTTPDataStream()
    #expect(stream.receive(streamHeaders()))
    let response = try await stream.response()
    #expect(response.status == 429)
    #expect(response.header("retry-after") == "2")
    let first = Data(repeating: 7, count: 150_123)
    let second = Data(repeating: 8, count: 70_000)
    stream.receive(first)
    stream.receive(second)
    stream.finish(fails ? URLError(.networkConnectionLost) : nil)
    var bytes = Data()
    do {
      while let chunk = try await stream.next() {
        #expect(chunk.count <= HTTPDataStream.chunkBytes)
        bytes.append(chunk)
      }
      #expect(!fails)
    } catch let error as URLError {
      #expect(fails)
      #expect(error.code == .networkConnectionLost)
    }
    #expect(bytes == first + second)
    #expect(stream.statistics.callbacks == 2)
    #expect(stream.statistics.bufferedBytes == 0)
  }
}

@Test func blockStreamHardLimitFailsExplicitlyAfterPreviouslyAcceptedBytes() async throws {
  let stream = HTTPDataStream()
  #expect(stream.receive(streamHeaders()))
  let bytes = Data(repeating: 9, count: HTTPDataStream.maximumBufferedBytes)
  stream.receive(bytes)
  stream.receive(Data([1]))
  #expect(stream.statistics.peakBufferedBytes == HTTPDataStream.maximumBufferedBytes)
  var count = 0
  do {
    while let chunk = try await stream.next() { count += chunk.count }
    Issue.record("超出缓冲上限必须返回错误")
  } catch let error as POSIXError { #expect(error.code == .ENOBUFS) }
  #expect(count == bytes.count)
}

@Test func blockStreamBackpressurePausesResumesAndExcludesConsumerWaitFromDeadline() async throws {
  let clock = ManualTestClock()
  try await withStartedStream(clock: clock) { stream, _ in
    #expect(stream.receive(streamHeaders()))
    stream.receive(Data(repeating: 1, count: HTTPDataStream.highWaterBytes))
    #expect(stream.statistics.pauses == 1)
    clock.advance(by: .seconds(600))
    while stream.statistics.bufferedBytes > HTTPDataStream.lowWaterBytes {
      #expect(try await stream.next() != nil)
    }
    #expect(stream.statistics.resumes == 1)
    stream.receive(Data([2]))
    stream.finish(nil)
    var remaining = Data()
    while let chunk = try await stream.next() { remaining.append(chunk) }
    #expect(remaining.count == HTTPDataStream.lowWaterBytes + 1)
    #expect(remaining.last == 2)
  }
}

@Test func blockStreamHeaderTimeoutCancelsUnderlyingTask() async throws {
  let clock = ManualTestClock()
  try await withStartedStream(clock: clock) { stream, control in
    await clock.waitForSleepRequests(1)
    clock.advance(by: .seconds(30))
    do { _ = try await stream.response(); Issue.record("首响应必须超时") }
    catch let error as URLError { #expect(error.code == .timedOut) }
    try await control.stopped.wait()
  }
}

@Test func blockStreamActualProgressExtendsIdleDeadlineAndLateDataCannotReviveIt() async throws {
  let clock = ManualTestClock()
  let stream = HTTPDataStream(clock: clock.deadlineClock)
  #expect(stream.receive(streamHeaders()))
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(40))
  stream.receive(Data([1]))
  clock.advance(by: .seconds(20))
  await clock.waitForSleepRequests(2)
  #expect(try await stream.next() == Data([1]))
  clock.advance(by: .seconds(40))
  stream.receive(Data([2]))
  do { _ = try await stream.next(); Issue.record("截止后的数据不得恢复流") }
  catch let error as URLError { #expect(error.code == .timedOut) }
  #expect(stream.statistics.receivedBytes == 1)
}

@Test func blockStreamCancellationDiscardsQueuedBytesAndStopsTask() async throws {
  try await withStartedStream(clock: ManualTestClock()) { stream, control in
    #expect(stream.receive(streamHeaders()))
    stream.receive(Data(repeating: 1, count: 200_000))
    stream.cancel()
    #expect(stream.statistics.bufferedBytes == 0)
    await #expect(throws: CancellationError.self) { try await stream.next() }
    try await control.stopped.wait()
  }
}

@Test func blockStreamAbandonedResponseStopsUnderlyingTask() async throws {
  let host = UUID().uuidString.lowercased() + ".invalid"
  let control = BlockStreamFixture.Control()
  BlockStreamFixture.controls.withLock { $0[host] = control }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [BlockStreamFixture.self]
  let session = URLSession(configuration: configuration)
  defer {
    session.invalidateAndCancel()
    _ = BlockStreamFixture.controls.withLock { $0.removeValue(forKey: host) }
  }
  var stream: HTTPDataStream? = HTTPDataStream()
  weak let released = stream
  stream?.start(session: session, request: URLRequest(url: URL(string: "https://" + host)!), cookieDomain: nil)
  try await control.started.wait()
  #expect(stream?.receive(streamHeaders()) == true)
  var body: AsyncThrowingStream<Data, Error>? = AsyncThrowingStream(unfolding: { [held = stream!] in
    try await held.next()
  })
  stream = nil
  #expect(released != nil)
  #expect(body != nil)
  body = nil
  #expect(released == nil)
  try await control.stopped.wait()
}

@Test func blockStreamCoalescesTinyCallbacksWithoutChangingBytes() async throws {
  let stream = HTTPDataStream()
  #expect(stream.receive(streamHeaders()))
  for _ in 0..<2048 { stream.receive(Data([3])) }
  #expect(stream.statistics.bufferedChunks == 1)
  stream.finish(nil)
  #expect(try await stream.next() == Data(repeating: 3, count: 2048))
  #expect(try await stream.next() == nil)
}
