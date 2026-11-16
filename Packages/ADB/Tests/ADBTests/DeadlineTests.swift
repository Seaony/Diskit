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

private actor SlowApprovalTransport: ADBTransport {
  let clock: ManualTestClock
  private var input: Data
  private var steps: [Duration]
  var timeouts: [TimeInterval] = []
  init(clock: ManualTestClock, messages: [ADBMessage], steps: [Duration]) {
    self.clock = clock
    input = messages.reduce(Data()) { $0 + $1.encoded() }
    self.steps = steps
  }
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    timeouts.append(timeout)
    if !steps.isEmpty { clock.advance(by: steps.removeFirst()) }
    guard !input.isEmpty else { throw RemoteError.posix(ETIMEDOUT) }
    let value = Data(input.prefix(count))
    input.removeFirst(value.count)
    return value
  }
  func write(_ data: Data, timeout: TimeInterval) async throws {}
  func close() async {}
}

// 发出公钥后手机弹「允许 USB 调试」，用户 30 秒后才点也要能连上，不能和握手共用 15 秒
@Test func authorizationPromptGetsItsOwnDeadline() async throws {
  let clock = ManualTestClock()
  let challenge = ADBMessage(.auth, 1, payload: Data(repeating: 1, count: 20))
  let transport = SlowApprovalTransport(
    clock: clock,
    messages: [
      challenge, challenge,
      ADBMessage(.connect, 0x0100_0001, 4096, payload: Data("device::features=shell_v2\0".utf8)),
    ],
    steps: [.seconds(1), .seconds(1), .seconds(1), .seconds(1), .seconds(30)])
  let session = ADBSession(
    transport: transport, identity: ADBIdentity(store: MemorySecretStore()), now: { clock.now })
  try await session.connect()
  #expect(await session.features == ["shell_v2"])
  let timeouts = await transport.timeouts
  #expect(timeouts.count == 6)
  #expect(abs(timeouts[4] - ADBSession.authorizationTimeout) < 0.0001)
  #expect(abs(timeouts[5] - (ADBSession.authorizationTimeout - 30)) < 0.0001)
}
