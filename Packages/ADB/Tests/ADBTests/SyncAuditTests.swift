import Core
import Foundation
import Synchronization
import Testing
@testable import ADB

private actor AuditTransport: ADBTransport {
  var input: Data
  var output = Data()
  let exhausted: RemoteError
  init(_ messages: [ADBMessage], exhausted: RemoteError = .notConnected) {
    input = messages.reduce(Data()) { $0 + $1.encoded() }
    self.exhausted = exhausted
  }
  func read(count: Int, timeout: TimeInterval) throws -> Data {
    guard !input.isEmpty else { throw exhausted }
    let result = Data(input.prefix(count)); input.removeFirst(result.count); return result
  }
  func write(_ data: Data, timeout: TimeInterval) { output.append(data) }
  func close() {}
}
private func auditHello(_ features: String) -> ADBMessage {
  .init(.connect, 0x0100_0001, 1_048_576, payload: Data("device::features=\(features)\0".utf8))
}
private func auditShell(_ id: UInt8, _ body: Data) -> Data {
  var result = Data([id]); result.appendLE(UInt32(body.count)); result.append(body); return result
}
private func auditService(_ local: UInt32, _ bytes: Data) -> [ADBMessage] {
  [.init(.okay, local, local), .init(.write, local, local, payload: bytes), .init(.close, local, local)]
}
private func auditProvider(_ transport: AuditTransport) -> ADBProvider {
  ADBProvider(session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
}

@Test func adbEmptyShellExitFailsImmediately() async throws {
  let transport = AuditTransport([auditHello("shell_v2")] + auditService(1, auditShell(3, Data())))
  let provider = auditProvider(transport)
  await #expect(throws: RemoteError.protocolError) { try await provider.connect() }
}

@Test func adbAvailableSpaceExcludesReservedBlocks() async throws {
  let output = Data("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/test 100 20 70 20% /sdcard\n".utf8)
  let transport = AuditTransport([auditHello("shell_v2")]
    + auditService(1, auditShell(3, Data([0])))
    + auditService(2, auditShell(1, output) + auditShell(3, Data([0]))))
  let provider = auditProvider(transport)
  try await provider.connect()
  let space = try await provider.spaceInfo()
  #expect(space.total == 102400)
  #expect(space.used == 20480)
  #expect(space.available == 71680)
}

@Test func adbVirtualPathsCannotEscapeInternalRoot() throws {
  #expect(try ADBSync.mapped(RemotePath("/sdcard/a"), sdPath: nil) == "/sdcard/sdcard/a")
  #expect(try ADBSync.mapped(RemotePath("/storage/a"), sdPath: nil) == "/sdcard/storage/a")
  #expect(try ADBSync.mapped(RemotePath("/SD 卡/a"), sdPath: "/storage/ABCD-1234") == "/storage/ABCD-1234/a")
  #expect(try ADBSync.mapped(RemotePath("/SD 卡/a"), sdPath: nil) == "/sdcard/SD 卡/a")
}

@Test func adbUploadRetainsOriginalModificationTime() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appending(path: "local")
  try Data("test".utf8).write(to: source)
  try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234567890)], ofItemAtPath: source.path)
  let transport = RecordingUploadTransport(base: LocalADBTransport(directory: directory))
  let provider = ADBProvider(session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  try await provider.write(RemotePath("/target"), from: source)
  let bytes = await transport.output
  var done = Data("DONE".utf8); done.appendLE(1234567890)
  #expect(bytes.range(of: done) != nil)
}
private actor RecordingUploadTransport: ADBTransport {
  let base: LocalADBTransport
  var output = Data()
  init(base: LocalADBTransport) { self.base = base }
  func read(count: Int, timeout: TimeInterval) async throws -> Data { try await base.read(count: count, timeout: timeout) }
  func write(_ data: Data, timeout: TimeInterval) async throws {
    output.append(data); try await base.write(data, timeout: timeout)
  }
  func close() async { await base.close() }
}

@Test func adbDownloadReportsActualReceivedBytes() async throws {
  var stat = Data("STA2".utf8); stat.appendLE(0)
  for _ in 0..<4 { stat.appendLE(0) }
  for value in [UInt32(0o100644), 1, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0] { stat.appendLE(value) }
  var frames = Data()
  for bytes in [Data("abc".utf8), Data("def".utf8)] {
    frames.append(Data("DATA".utf8)); frames.appendLE(UInt32(bytes.count)); frames.append(bytes)
  }
  frames.append(Data("DONE".utf8)); frames.appendLE(0)
  let transport = AuditTransport([
    auditHello("stat_v2,sendrecv_v2"), .init(.okay, 1, 1), .init(.okay, 1, 1),
    .init(.write, 1, 1, payload: stat), .init(.close, 1, 1),
    .init(.okay, 2, 2), .init(.okay, 2, 2), .init(.okay, 2, 2),
    .init(.write, 2, 2, payload: frames), .init(.close, 2, 2),
  ])
  let provider = auditProvider(transport)
  let values = Mutex<[Int64]>([])
  await provider.onProgress { received, total in
    #expect(total == 6)
    values.withLock { $0.append(received) }
  }
  try await provider.connect()
  for try await _ in try await provider.read(RemotePath("/test"), range: nil) {}
  #expect(values.withLock { $0 } == [3, 6])
}

@Test func adbSDCardAliasRejectsRealDirectoryCollision() async throws {
  var dent = Data("DENT".utf8)
  for value in [UInt32(0o40755), 0, 0, UInt32("SD 卡".utf8.count)] { dent.appendLE(value) }
  dent.append(Data("SD 卡".utf8)); dent.append(Data("DONE".utf8)); dent.append(Data(repeating: 0, count: 16))
  let transport = AuditTransport([auditHello("shell_v2")]
    + auditService(1, auditShell(1, Data("/storage/ABCD-1234\n".utf8)) + auditShell(3, Data([0])))
    + [.init(.okay, 2, 2), .init(.okay, 2, 2), .init(.write, 2, 2, payload: dent), .init(.close, 2, 2)])
  let provider = auditProvider(transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) { _ = try await provider.list(RemotePath("/")) }
}

@Test func adbAuthorizationTimeoutAsksForPhoneApproval() async throws {
  let challenge = ADBMessage(.auth, 1, payload: Data(repeating: 1, count: 20))
  let transport = AuditTransport([challenge, challenge], exhausted: .posix(ETIMEDOUT))
  let provider = auditProvider(transport)
  await #expect(throws: RemoteError.unauthorized) { try await provider.connect() }
}

@Test func adbLegacyStatRecoversSizeAboveFourGiB() async throws {
  var stat = Data("STAT".utf8)
  for value in [UInt32(0o100644), UInt32(truncatingIfNeeded: 5_000_000_000 as UInt64), 1] { stat.appendLE(value) }
  let transport = AuditTransport([auditHello("shell_v2")]
    + auditService(1, auditShell(3, Data([0])))
    + [.init(.okay, 2, 2), .init(.okay, 2, 2), .init(.write, 2, 2, payload: stat), .init(.close, 2, 2)]
    + auditService(3, auditShell(1, Data("5000000000\n".utf8)) + auditShell(3, Data([0]))))
  let provider = auditProvider(transport)
  try await provider.connect()
  #expect(try await provider.stat(RemotePath("/large")).size == 5_000_000_000)
  let output = String(decoding: await transport.output, as: UTF8.self)
  #expect(output.contains("stat -c %s -- '/sdcard/large'"))
}

// v1 的 RECV 按 DATA 块一直发到 DONE，没有总大小限制；大小用 stat -c %s 补回 32 位以上
@Test func adbLegacyDownloadAllowsFilesAboveFourGiB() async throws {
  var stat = Data("STAT".utf8)
  for value in [UInt32(0o100644), UInt32(truncatingIfNeeded: 5_000_000_000 as UInt64), 1] { stat.appendLE(value) }
  var frames = Data("DATA".utf8); frames.appendLE(3); frames.append(Data("abc".utf8))
  frames.append(Data("DONE".utf8)); frames.appendLE(0)
  let transport = AuditTransport([auditHello("shell_v2")]
    + auditService(1, auditShell(3, Data([0])))
    + [.init(.okay, 2, 2), .init(.okay, 2, 2), .init(.write, 2, 2, payload: stat), .init(.close, 2, 2)]
    + auditService(3, auditShell(1, Data("5000000000\n".utf8)) + auditShell(3, Data([0])))
    + [.init(.okay, 4, 4), .init(.okay, 4, 4), .init(.write, 4, 4, payload: frames), .init(.close, 4, 4)])
  let provider = auditProvider(transport)
  let totals = Mutex<[Int64]>([])
  await provider.onProgress { _, total in totals.withLock { $0.append(total) } }
  try await provider.connect()
  var received = Data()
  for try await chunk in try await provider.read(RemotePath("/large"), range: nil) { received.append(chunk) }
  #expect(received == Data("abc".utf8))
  #expect(totals.withLock { $0 } == [5_000_000_000])
  #expect(String(decoding: await transport.output, as: UTF8.self).contains("RECV"))
}
