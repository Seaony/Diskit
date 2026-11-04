import Core
import CoreTestSupport
import Foundation
import Network
import Synchronization
import Testing
@testable import ADB

private final class FakeNetworkIO: ADBNetworkIO, Sendable {
  struct State {
    var startStates: [NWConnection.State] = [.ready]
    var received: Data? = Data([1, 2])
    var receiveError: NWError?
    var sendError: NWError?
    var secret: Data? = Data(repeating: 1, count: 64)
    var suspend = false
    var cancelCount = 0
    var sent = Data()
  }
  let state = Mutex(State())
  let registered = TestEvent()
  func start(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
    let values = state.withLock { $0.startStates }
    registered.signal()
    for value in values { handler(value) }
  }
  func stopObservingState() {}
  func receive(count: Int, completion: @escaping @Sendable (Data?, NWError?) -> Void) {
    let values = state.withLock { ($0.received, $0.receiveError, $0.suspend) }
    registered.signal()
    if !values.2 { completion(values.0, values.1) }
  }
  func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
    let values = state.withLock { value in value.sent = data; return (value.sendError, value.suspend) }
    registered.signal()
    if !values.1 { completion(values.0) }
  }
  func exportedSecret() -> Data? { state.withLock { $0.secret } }
  func cancel() { state.withLock { $0.cancelCount += 1 } }
}

@Test func networkStartIgnoresPreparingAndCompletesOnlyOnce() async throws {
  let io = FakeNetworkIO()
  io.state.withLock { $0.startStates = [.setup, .preparing, .ready, .failed(.posix(.ECONNRESET))] }
  try await NetworkTransport(io: io).start()
}

@Test(arguments: [false, true])
func networkStartReportsRefusalWithoutWaiting(waiting: Bool) async {
  let io = FakeNetworkIO()
  io.state.withLock { $0.startStates = [waiting ? .waiting(.posix(.ECONNREFUSED)) : .failed(.posix(.ECONNREFUSED))] }
  do {
    try await NetworkTransport(io: io).start()
    Issue.record("拒绝连接必须失败")
  } catch { #expect((error as NSError).code == Int(ECONNREFUSED)) }
}

@Test func networkCancelledConnectionCannotStart() async {
  let io = FakeNetworkIO()
  io.state.withLock { $0.startStates = [.cancelled] }
  await #expect(throws: RemoteError.notConnected) { try await NetworkTransport(io: io).start() }
}

@Test func networkReadsAndWritesExactBytes() async throws {
  let io = FakeNetworkIO()
  let transport = NetworkTransport(io: io)
  #expect(try await transport.read(count: 4, timeout: 5) == Data([1, 2]))
  try await transport.write(Data([3, 4]), timeout: 5)
  #expect(io.state.withLock { $0.sent } == Data([3, 4]))
  #expect(try await transport.exporter() == Data(repeating: 1, count: 64))
  await transport.close()
  #expect(io.state.withLock { $0.cancelCount } == 1)
}

@Test(arguments: [nil, Data()])
func networkEmptyReceiveIsDisconnected(data: Data?) async {
  let io = FakeNetworkIO()
  io.state.withLock { $0.received = data }
  await #expect(throws: RemoteError.notConnected) {
    try await NetworkTransport(io: io).read(count: 4, timeout: 5)
  }
}

@Test func networkRejectsInvalidReceiveLength() async {
  let io = FakeNetworkIO()
  let transport = NetworkTransport(io: io)
  await #expect(throws: RemoteError.protocolError) { try await transport.read(count: 1, timeout: 5) }
  await #expect(throws: RemoteError.invalidPath) { try await transport.read(count: 0, timeout: 5) }
}

@Test(arguments: [false, true])
func networkIOErrorsKeepPOSIXMeaning(write: Bool) async {
  let io = FakeNetworkIO()
  io.state.withLock { $0.receiveError = .posix(.ECONNRESET); $0.sendError = .posix(.EPIPE) }
  let transport = NetworkTransport(io: io)
  do {
    if write { try await transport.write(Data([1]), timeout: 5) }
    else { _ = try await transport.read(count: 4, timeout: 5) }
    Issue.record("网络错误必须返回")
  } catch { #expect((error as NSError).code == Int(write ? EPIPE : ECONNRESET)) }
}

@Test(arguments: [nil, Data(), Data(repeating: 1, count: 63), Data(repeating: 1, count: 65)])
func networkExporterRejectsMissingOrWrongLength(secret: Data?) async {
  let io = FakeNetworkIO()
  io.state.withLock { $0.secret = secret }
  await #expect(throws: RemoteError.protocolError) { try await NetworkTransport(io: io).exporter() }
}

@Test(arguments: ["start", "read", "write"])
func networkDeadlineCancelsSuspendedOperation(operation: String) async throws {
  let io = FakeNetworkIO()
  let clock = ManualTestClock()
  io.state.withLock { $0.startStates = [.preparing]; $0.suspend = true }
  let transport = NetworkTransport(io: io, sleep: { try await clock.sleep(for: $0) })
  let task = Task {
    if operation == "start" { try await transport.start() }
    else if operation == "read" { _ = try await transport.read(count: 4, timeout: 15) }
    else { try await transport.write(Data([1]), timeout: 15) }
  }
  try await io.registered.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(15))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await task.value }
  #expect(io.state.withLock { $0.cancelCount } == 1)
}

@Test func networkCallerCancellationDoesNotWaitForCallback() async throws {
  let io = FakeNetworkIO()
  io.state.withLock { $0.suspend = true }
  let task = Task { try await NetworkTransport(io: io).read(count: 4, timeout: 15) }
  try await io.registered.wait()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(io.state.withLock { $0.cancelCount } == 1)
}

@Test func startTLSHelloAdvertisesOnlySupportedSyncFeatures() throws {
  let packet = try ADBMessage.decode(ADBStartTLSProtocol.hello)
  #expect(packet.command == .connect)
  #expect(packet.arg0 == 0x0100_0001)
  #expect(packet.arg1 == 1_048_576)
  #expect(packet.payload == Data("host::features=shell_v2,stat_v2,ls_v2,sendrecv_v2\0".utf8))
}

@Test(arguments: [0.0, -1.0, Double.infinity, Double.nan])
func networkInvalidDeadlineNeverStartsIO(timeout: Double) async {
  let io = FakeNetworkIO()
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await NetworkTransport(io: io).read(count: 1, timeout: timeout)
  }
  #expect(!io.registered.isSignaled)
}
