import Core
import Foundation
import Testing

@testable import ADB

private actor TestUSBChannel: USBChannel {
  nonisolated let packetSize: Int
  var reads: [Data]
  var counts: [Int]
  var error: (any Error)?
  private(set) var writes: [Data] = []
  private(set) var closed = 0
  init(packetSize: Int = 4, reads: [Data] = [], counts: [Int] = [], error: (any Error)? = nil) {
    self.packetSize = packetSize
    self.reads = reads
    self.counts = counts
    self.error = error
  }
  func read(count: Int, timeout: TimeInterval) throws -> Data {
    if let error { throw error }
    guard !reads.isEmpty else { throw RemoteError.notConnected }
    return reads.removeFirst()
  }
  func write(_ data: Data, timeout: TimeInterval) throws -> Int {
    if let error { throw error }
    writes.append(data)
    return counts.isEmpty ? data.count : counts.removeFirst()
  }
  func close() { closed += 1 }
}

@Test func usbReadIgnoresZeroPacketAndEnforcesRequestedLength() async throws {
  let channel = TestUSBChannel(reads: [Data(), Data([1, 2]), Data([1, 2, 3])])
  let transport = USBTransport(channel: channel)
  #expect(try await transport.read(count: 2, timeout: 10) == Data([1, 2]))
  await #expect(throws: RemoteError.protocolError) {
    try await transport.read(count: 2, timeout: 10)
  }
  await #expect(throws: RemoteError.protocolError) {
    try await transport.read(count: 0, timeout: 10)
  }
}

@Test(arguments: [0, 3, 4, 8]) func usbWriteTerminatesOnlyFullPackets(count: Int) async throws {
  let channel = TestUSBChannel()
  let transport = USBTransport(channel: channel)
  let bytes = Data(repeating: 1, count: count)
  try await transport.write(bytes, timeout: 10)
  #expect(await channel.writes == (count > 0 && count % 4 == 0 ? [bytes, Data()] : [bytes]))
}

@Test func usbWriteRejectsShortTransfersAndInvalidZeroPacket() async throws {
  let short = USBTransport(channel: TestUSBChannel(counts: [2]))
  await #expect(throws: RemoteError.notConnected) {
    try await short.write(Data([1, 2, 3]), timeout: 10)
  }
  let badZero = USBTransport(channel: TestUSBChannel(counts: [4, 1]))
  await #expect(throws: RemoteError.protocolError) {
    try await badZero.write(Data(repeating: 1, count: 4), timeout: 10)
  }
  let badPacket = USBTransport(channel: TestUSBChannel(packetSize: 0))
  await #expect(throws: RemoteError.protocolError) {
    try await badPacket.write(Data([1]), timeout: 10)
  }
}

@Test func usbCloseIsIdempotentAndStopsFurtherRequests() async throws {
  let channel = TestUSBChannel()
  let transport = USBTransport(channel: channel)
  await transport.close()
  await transport.close()
  #expect(await channel.closed == 1)
  await #expect(throws: RemoteError.notConnected) {
    try await transport.read(count: 1, timeout: 10)
  }
  await #expect(throws: RemoteError.notConnected) {
    try await transport.write(Data([1]), timeout: 10)
  }
}

@Test func usbTransportPreservesTimeoutAndCancellation() async throws {
  let failed = USBTransport(channel: TestUSBChannel(error: POSIXError(.EACCES)))
  await #expect(throws: POSIXError(.EACCES)) { try await failed.read(count: 1, timeout: 10) }
  await #expect(throws: POSIXError(.EACCES)) { try await failed.write(Data([1]), timeout: 10) }
  let cancelled = USBTransport(channel: TestUSBChannel(error: CancellationError()))
  await #expect(throws: CancellationError.self) { try await cancelled.read(count: 1, timeout: 10) }
  let expired = USBTransport(channel: TestUSBChannel())
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await expired.read(count: 1, timeout: 0)
  }
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await expired.write(Data([1]), timeout: 0)
  }
}
