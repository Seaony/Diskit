import Core
import Foundation
import Security
import Synchronization
import Testing

@testable import ADB

private final class TestSecrets: SecretStore, Sendable {
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

private actor FakeTransport: ADBTransport {
  var input: Data
  var sent: [Data] = []
  var closed = false
  let fragment: Int
  init(_ messages: [ADBMessage], fragment: Int = 7) {
    input = messages.reduce(Data()) { $0 + $1.encoded() }
    self.fragment = fragment
  }
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !closed, !input.isEmpty else { throw RemoteError.notConnected }
    let size = min(count, fragment, input.count)
    let value = Data(input.prefix(size))
    input.removeFirst(size)
    return value
  }
  func write(_ data: Data, timeout: TimeInterval) async throws {
    guard !closed else { throw RemoteError.notConnected }
    sent.append(data)
  }
  func close() async { closed = true }
  func output() -> Data { sent.reduce(Data(), +) }
}

private func hello(_ features: String = "stat_v2,ls_v2,sendrecv_v2") -> ADBMessage {
  ADBMessage(
    .connect, 0x0100_0001, 1_048_576, payload: Data(("device::features=" + features + "\0").utf8))
}
private func statV2(size: UInt64 = 5_000_000_000, mode: UInt32 = 0o100664, error: UInt32 = 0)
  -> Data
{
  var d = Data()
  for v in [ADBSync.id("STA2"), error] { d.appendLE(v) }
  func add64(_ v: UInt64) {
    d.appendLE(UInt32(truncatingIfNeeded: v))
    d.appendLE(UInt32(truncatingIfNeeded: v >> 32))
  }
  add64(1)
  add64(2)
  for v in [mode, 1, 1000, 1000] { d.appendLE(v) }
  add64(size)
  add64(1)
  add64(2)
  add64(3)
  return d
}
private func dataFrame(_ text: String) -> Data {
  var d = Data()
  d.appendLE(ADBSync.id("DATA"))
  d.appendLE(UInt32(text.utf8.count))
  d.append(Data(text.utf8))
  return d
}
private func syncDone() -> Data {
  var d = Data()
  d.appendLE(ADBSync.id("DONE"))
  d.appendLE(0)
  return d
}

@Test func fixedWirePacketAndChecksumRules() throws {
  // AOSP 的 OKAY 消息：远端 ID 1、本地 ID 2、空负载，固定小端字节。
  let fixed = Data([
    0x4f, 0x4b, 0x41, 0x59, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xb0, 0xb4, 0xbe, 0xa6,
  ])
  let packet = try ADBMessage.decode(fixed)
  #expect(packet == ADBMessage(.okay, 1, 2))
  #expect(packet.encoded() == fixed)
  let sample = ADBMessage(.write, 1, 2, payload: Data([0, 128, 255]))
  #expect(ADBMessage.checksum(sample.payload) == 383)
  var badChecksum = sample.encoded()
  badChecksum[16] ^= 1
  #expect(throws: RemoteError.protocolError) { try ADBMessage.decode(badChecksum) }
  #expect(try ADBMessage.decode(badChecksum, skipChecksum: true) == sample)
  var badMagic = fixed
  badMagic[23] = 0
  #expect(throws: RemoteError.protocolError) { try ADBMessage.decode(badMagic, skipChecksum: true) }
  #expect(throws: RemoteError.protocolError) { try ADBMessage.decode(fixed.dropLast()) }
  var huge = fixed
  huge[15] = 0xff
  #expect(throws: RemoteError.protocolError) { try ADBMessage.decode(huge) }
}

@Test func androidPublicKeyMatchesOfficialADB() throws {
  let folder = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures"))
  let der = try Data(contentsOf: folder.appending(path: "android-public.der"))
  let expected = try String(contentsOf: folder.appending(path: "adbkey.pub"), encoding: .utf8)
    .split(separator: " ")[0]
  let encoded = try ADBIdentity.encode(publicDER: der)
  #expect(encoded.count == 524)
  #expect(encoded.base64EncodedString() == expected)
  #expect(throws: RemoteError.protocolError) { try ADBIdentity.encode(publicDER: Data([1, 2, 3])) }
}

@Test func systemSignatureAndIdentityPersist() throws {
  let secrets = TestSecrets()
  let identity = ADBIdentity(store: secrets)
  let token = Data(repeating: 42, count: 20)
  let signature = try identity.sign(token)
  let privateDER = try #require(try secrets.read("adb.private-key"))
  let key = try #require(
    SecKeyCreateWithData(
      privateDER as CFData,
      [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        as CFDictionary, nil))
  let publicKey = try #require(SecKeyCopyPublicKey(key))
  #expect(
    SecKeyVerifySignature(
      publicKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, signature as CFData, nil))
  #expect(try ADBIdentity(store: secrets).publicKeyData() == identity.publicKeyData())
  let line = try identity.publicKeyLine()
  #expect(line.last == 0)
  #expect(String(decoding: line, as: UTF8.self).contains("@"))
  let previous = try identity.fingerprint()
  try identity.regenerate()
  #expect(try identity.fingerprint() != previous)
}

@Test func authorizationExchangesSignatureThenPublicKey() async throws {
  let token = Data(repeating: 1, count: 20)
  let transport = FakeTransport([
    ADBMessage(.auth, 1, payload: token), ADBMessage(.auth, 1, payload: token), hello(),
  ])
  let session = ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets()))
  try await session.connect()
  #expect(await session.features.contains("sendrecv_v2"))
  var bytes = await transport.output()
  var packets: [ADBMessage] = []
  while !bytes.isEmpty {
    var r = BinaryReader(Data(bytes[12..<16]))
    let length = 24 + Int(try r.u32())
    packets.append(try ADBMessage.decode(Data(bytes.prefix(length))))
    bytes = Data(bytes.dropFirst(length))
  }
  #expect(packets.map(\.command) == [.connect, .auth, .auth])
  #expect(packets[1].arg0 == 2 && packets[1].payload.count == 256)
  #expect(packets[2].arg0 == 3 && packets[2].payload.last == 0)
}

@Test func syncV1AndV2PreserveSizesAndErrors() throws {
  var v1 = Data()
  for word in [ADBSync.id("STAT"), 0o100664, UInt32.max, 123] { v1.appendLE(word) }
  #expect(try ADBSync.decodeStat(v1, path: RemotePath("/file"), v2: false).size == 4_294_967_295)
  #expect(
    try ADBSync.decodeStat(statV2(), path: RemotePath("/file"), v2: true).size == 5_000_000_000)
  #expect(throws: RemoteError.posix(EACCES)) {
    try ADBSync.decodeStat(statV2(error: UInt32(EACCES)), path: RemotePath("/file"), v2: true)
  }
  let name = "照片 空格😀.jpg"
  var dent = statV2()
  dent.replaceSubrange(0..<4, with: Data("DNT2".utf8))
  dent.appendLE(UInt32(name.utf8.count))
  #expect(
    try ADBSync.decodeDent(dent, name: name, parent: RemotePath("/DCIM"), v2: true).path.value
      == "/DCIM/" + name)
  #expect(throws: RemoteError.protocolError) {
    try ADBSync.decodeDent(dent, name: "wrong", parent: RemotePath("/"), v2: true)
  }
}

@Test func shellArgumentsAndRemotePathsRejectTraversal() throws {
  #expect(try ADBShell.quote("a'b $(rm -rf x) 😀") == "'a'\\''b $(rm -rf x) 😀'")
  #expect(throws: RemoteError.invalidPath) { try ADBShell.quote("bad\0path") }
  #expect(throws: RemoteError.invalidPath) { try RemotePath("/a/../b") }
  #expect(throws: RemoteError.invalidPath) { try RemotePath("/").appending("../outside") }
  #expect(try RemotePath("//sdcard/./DCIM/").value == "/sdcard/DCIM")
}

@Test func streamedDownloadReadsChunksAndClosesService() async throws {
  let stat = statV2(size: 6)
  let transport = FakeTransport([
    hello(), .init(.okay, 11, 1), .init(.okay, 11, 1), .init(.write, 11, 1, payload: stat),
    .init(.close, 11, 1),
    .init(.okay, 12, 2), .init(.okay, 12, 2), .init(.okay, 12, 2),
    .init(.write, 12, 2, payload: dataFrame("abc") + dataFrame("def") + syncDone()),
    .init(.close, 12, 2),
  ])
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
  try await provider.connect()
  var chunks: [Data] = []
  for try await chunk in try await provider.read(RemotePath("/DCIM/test"), range: nil) {
    chunks.append(chunk)
  }
  #expect(chunks == [Data("abc".utf8), Data("def".utf8)])
  await provider.disconnect()
  #expect(await transport.closed)
}

@Test func interruptedTransferReturnsError() async throws {
  let transport = FakeTransport([hello(), .init(.okay, 11, 1), .init(.okay, 11, 1)])
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
  try await provider.connect()
  await #expect(throws: RemoteError.notConnected) {
    try await provider.stat(RemotePath("/missing"))
  }
  #expect(await transport.closed)
}

@Test func syncUploadWritesDataAndDoneWithoutWholeFileBuffer() async throws {
  var okay = Data("OKAY".utf8)
  okay.appendLE(0)
  let transport = FakeTransport([
    hello(), .init(.okay, 11, 1), .init(.okay, 11, 1), .init(.okay, 11, 1), .init(.okay, 11, 1),
    .init(.okay, 11, 1), .init(.write, 11, 1, payload: okay), .init(.close, 11, 1),
  ])
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("test contents".utf8).write(to: url)
  try await provider.connect()
  try await provider.write(RemotePath("/中文 空格😀"), from: url)
  let output = await transport.output()
  #expect(output.range(of: Data("SND2".utf8)) != nil)
  #expect(output.range(of: Data("test contents".utf8)) != nil)
  #expect(output.range(of: Data("DONE".utf8)) != nil)
  await provider.disconnect()
}

@Test func listingV1AndV2DecodeDirectoryEntries() async throws {
  for v2 in [false, true] {
    let name = "文件 😀.txt"
    var dent = Data()
    if v2 {
      dent = statV2(size: 12)
      dent.replaceSubrange(0..<4, with: Data("DNT2".utf8))
    } else {
      for word in [ADBSync.id("DENT"), 0o100664, 12, 2] { dent.appendLE(word) }
    }
    dent.appendLE(UInt32(name.utf8.count))
    dent.append(Data(name.utf8))
    var done = Data("DONE".utf8)
    done.append(Data(repeating: 0, count: (v2 ? 76 : 20) - 4))
    let transport = FakeTransport([
      hello(v2 ? "ls_v2" : ""), .init(.okay, 11, 1), .init(.okay, 11, 1),
      .init(.write, 11, 1, payload: dent + done), .init(.close, 11, 1),
    ])
    let provider = ADBProvider(
      session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
    try await provider.connect()
    let result = try await provider.list(RemotePath("/DCIM"))
    #expect(result.count == 1)
    #expect(result.first?.size == 12)
    #expect(result.first?.path.value == "/DCIM/" + name)
    await provider.disconnect()
  }
}

private func shellFrame(_ id: UInt8, _ bytes: Data) -> Data {
  var frame = Data([id])
  frame.appendLE(UInt32(bytes.count))
  frame.append(bytes)
  return frame
}

@Test func shellExitCodeIsCheckedAndSDCardAppears() async throws {
  let sd = shellFrame(1, Data("/storage/ABCD-1234\n".utf8)) + shellFrame(3, Data([0]))
  var emptyList = Data("DONE".utf8)
  emptyList.append(Data(repeating: 0, count: 72))
  let failure = shellFrame(2, Data("mkdir: Permission denied\n".utf8)) + shellFrame(3, Data([1]))
  let transport = FakeTransport([
    hello("shell_v2,ls_v2"), .init(.okay, 11, 1), .init(.write, 11, 1, payload: sd),
    .init(.close, 11, 1),
    .init(.okay, 12, 2), .init(.okay, 12, 2), .init(.write, 12, 2, payload: emptyList),
    .init(.close, 12, 2),
    .init(.okay, 13, 3), .init(.write, 13, 3, payload: failure), .init(.close, 13, 3),
  ])
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).map(\.name) == ["SD 卡"])
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await provider.makeDirectory(RemotePath("/a'b"))
  }
  let output = String(decoding: await transport.output(), as: UTF8.self)
  #expect(output.contains("mkdir -p -- '/sdcard/a'\\''b'"))
}

@Test func legacyTransferRejectsLargeFilesBeforeUpload() async throws {
  let transport = FakeTransport([hello("")])
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: TestSecrets())))
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  FileManager.default.createFile(atPath: url.path, contents: nil)
  let handle = try FileHandle(forWritingTo: url)
  try handle.truncate(atOffset: 5_000_000_000)
  try handle.close()
  try await provider.connect()
  await #expect(throws: RemoteError.tooLarge) {
    try await provider.write(RemotePath("/large"), from: url)
  }
  await provider.disconnect()
}
