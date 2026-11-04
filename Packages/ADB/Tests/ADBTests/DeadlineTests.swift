import Core
import CoreTestSupport
import Foundation
import Testing

@testable import ADB

@Test func ordinaryADBDeadlineDoesNotRenewOnProgress() async throws {
  let clock = ManualTestClock()
  let deadline = ADBOperationDeadline(timeout: 15, now: { clock.now })
  for _ in 0..<5 {
    clock.advance(by: .seconds(4))
    deadline.transferred(10)
  }
  #expect(throws: RemoteError.posix(ETIMEDOUT)) { _ = try deadline.remaining() }
}

@Test func transferADBDeadlineRenewsOnlyForBytes() async throws {
  let clock = ManualTestClock()
  let deadline = ADBOperationDeadline(timeout: 15, isTransfer: true, now: { clock.now })
  for _ in 0..<5 {
    clock.advance(by: .seconds(4))
    deadline.transferred(10)
    #expect(try deadline.remaining() > 0)
  }
  clock.advance(by: .seconds(18))
  deadline.transferred(0)
  deadline.transferred(10)
  #expect(throws: RemoteError.posix(ETIMEDOUT)) { _ = try deadline.remaining() }
}

private actor FragmentedDeadlineTransport: ADBTransport {
  let clock: ManualTestClock
  init(clock: ManualTestClock) { self.clock = clock }
  private var input = ADBMessage(.connect, 0x0100_0001, 4096).encoded()
  var timeouts: [TimeInterval] = []
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    timeouts.append(timeout)
    clock.advance(by: .milliseconds(100))
    guard !input.isEmpty else { throw RemoteError.notConnected }
    return Data([input.removeFirst()])
  }
  func write(_ data: Data, timeout: TimeInterval) async throws {}
  func close() async {}
}

@Test func fragmentedADBHeaderUsesOneConnectDeadline() async throws {
  let clock = ManualTestClock()
  let transport = FragmentedDeadlineTransport(clock: clock)
  let session = ADBSession(transport: transport, initialConnectSent: true, now: { clock.now })
  try await session.connect()
  let timeouts = await transport.timeouts
  #expect(timeouts.count == 24)
  let first = try #require(timeouts.first)
  let last = try #require(timeouts.last)
  #expect(first <= RemoteTimeout.deviceRequest)
  #expect(abs((first - last) - 2.3) < 0.0001)
}
