import Core
import CryptoKit
import Foundation
import Testing

@testable import ADB

private actor PairingPhone: ADBTransport {
  private let spake: PairingSPAKE
  private var cipher: PairingCipher?
  private var input = Data()
  private var stage = 0
  private let guid: String
  private let tamper: Bool
  private(set) var publicKey: Data?
  private(set) var kinds: [PairingHeader.Kind] = []
  init(code: String, exporter: Data, guid: String = "adb-phone-guid", tamper: Bool = false) throws {
    spake = try PairingSPAKE(password: Data(code.utf8) + exporter, server: true)
    self.guid = guid
    self.tamper = tamper
  }
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !input.isEmpty else { throw RemoteError.notConnected }
    let result = Data(input.prefix(min(7, count)))
    input.removeFirst(result.count)
    return result
  }
  func write(_ data: Data, timeout: TimeInterval) async throws {
    let header = try PairingHeader(Data(data.prefix(6)))
    guard data.count == header.length + 6 else { throw PairingError.invalidPacket }
    kinds.append(header.kind)
    let payload = Data(data.dropFirst(6))
    if stage == 0 {
      guard header.kind == .spake else { throw PairingError.invalidPacket }
      cipher = PairingCipher(material: try spake.sharedKey(peer: payload))
      input = try PairingHeader(kind: .spake, length: spake.message.count).encoded + spake.message
    } else {
      guard stage == 1, header.kind == .peerInfo, var cipher else {
        throw PairingError.invalidPacket
      }
      var info = Data(repeating: 0, count: 8192)
      info[0] = 1
      info.replaceSubrange(1..<(1 + guid.utf8.count), with: guid.utf8)
      var encrypted = try cipher.encrypt(info)
      if tamper { encrypted[encrypted.count - 1] ^= 1 }
      input = try PairingHeader(kind: .peerInfo, length: encrypted.count).encoded + encrypted
      if let clear = try? cipher.decrypt(payload), clear.count == 8192, clear[0] == 0,
        let end = clear.dropFirst().firstIndex(of: 0)
      {
        publicKey = clear.subdata(in: 1..<end)
      }
      self.cipher = cipher
    }
    stage += 1
  }
  func close() async { input = Data() }
}

private actor PairingBytes: ADBTransport {
  var input: Data
  init(_ input: Data) { self.input = input }
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !input.isEmpty else { throw RemoteError.notConnected }
    let value = Data(input.prefix(count))
    input.removeFirst(value.count)
    return value
  }
  func write(_ data: Data, timeout: TimeInterval) async throws {}
  func close() async {}
}

@Test func PairingFrameUsesAOSPBigEndianLengthAndRejectsInvalidHeader() throws {
  let expected = Data([1, 1, 0, 0, 0x20, 0x10])
  let header = try PairingHeader(expected)
  #expect(header.kind == .peerInfo)
  #expect(header.length == 8208)
  #expect(header.encoded == expected)
  for bytes: [UInt8] in [
    [2, 0, 0, 0, 0, 32], [1, 2, 0, 0, 0, 32], [1, 0, 0, 0, 0, 0],
    [1, 0, 0, 0, 0x40, 1], [1, 0, 0, 0, 32],
  ] {
    #expect(throws: PairingError.invalidPacket) { try PairingHeader(Data(bytes)) }
  }
  #expect(try PairingHeader(kind: .spake, length: 32).encoded == Data([1, 0, 0, 0, 0, 32]))
}

@Test func PairingSPAKEAgreesAndUsesFreshContext() throws {
  let password = Data("123456".utf8) + Data(repeating: 0x42, count: 64)
  let client = try PairingSPAKE(password: password)
  let server = try PairingSPAKE(password: password, server: true)
  #expect(client.message.count == 32)
  #expect(server.message.count == 32)
  let clientKey = try client.sharedKey(peer: server.message)
  let serverKey = try server.sharedKey(peer: client.message)
  #expect(clientKey == serverKey)
  #expect(clientKey.count == 64)
  #expect(throws: PairingError.invalidPacket) { try client.sharedKey(peer: server.message) }
  let other = try PairingSPAKE(password: password)
  #expect(other.message != client.message)
  #expect(throws: PairingError.invalidPacket) {
    try other.sharedKey(peer: Data(repeating: 0, count: 31))
  }
}

@Test func PairingCipherHasSeparateCountersAndOmitsNonceFromPayload() throws {
  let material = Data(repeating: 0x23, count: 64)
  var client = PairingCipher(material: material)
  var server = PairingCipher(material: material)
  let clear = Data(repeating: 0x31, count: 8192)
  let first = try client.encrypt(clear)
  #expect(first.count == 8208)
  #expect(try server.decrypt(first) == clear)
  let second = try client.encrypt(clear)
  #expect(first != second)
  #expect(try server.decrypt(second) == clear)
  let response = try server.encrypt(Data("response".utf8))
  #expect(try client.decrypt(response) == Data("response".utf8))
  #expect(throws: PairingError.wrongCode) { try client.decrypt(response) }
}

@Test func PairingCorrectCodeReturnsGUIDAndSendsPublicKey() async throws {
  let exporter = Data(repeating: 0xa5, count: 64)
  let phone = try PairingPhone(code: "123456", exporter: exporter)
  let key = Data("test-base64 user@host\0".utf8)
  let guid = try await ADBPairing.exchange(
    transport: phone, exporter: exporter, code: "123456", publicKey: key)
  #expect(guid == "adb-phone-guid")
  #expect(await phone.publicKey == Data(key.dropLast()))
  #expect(await phone.kinds == [.spake, .peerInfo])
}

@Test func PairingWrongCodeAndWrongExporterCannotAuthenticate() async throws {
  let exporter = Data(repeating: 0xa5, count: 64)
  for wrongExporter in [false, true] {
    let phone = try PairingPhone(code: "123456", exporter: exporter)
    await #expect(throws: PairingError.wrongCode) {
      try await ADBPairing.exchange(
        transport: phone,
        exporter: wrongExporter ? Data(repeating: 0xb5, count: 64) : exporter,
        code: wrongExporter ? "123456" : "123457", publicKey: Data("key\0".utf8))
    }
    #expect(await phone.publicKey == nil)
  }
  #expect(PairingError.wrongCode.errorDescription == L("配对码错误"))
}

@Test func PairingRejectsTamperedCiphertextAndEmptyGUID() async throws {
  let exporter = Data(repeating: 0xa5, count: 64)
  let phone = try PairingPhone(code: "123456", exporter: exporter, tamper: true)
  await #expect(throws: PairingError.wrongCode) {
    try await ADBPairing.exchange(
      transport: phone, exporter: exporter, code: "123456", publicKey: Data("key\0".utf8))
  }
  let empty = try PairingPhone(code: "123456", exporter: exporter, guid: "")
  await #expect(throws: PairingError.invalidPacket) {
    try await ADBPairing.exchange(
      transport: empty, exporter: exporter, code: "123456", publicKey: Data("key\0".utf8))
  }
}

@Test func PairingRejectsInvalidCodeAndUnexpectedFrameBeforePeerInfo() async throws {
  for code in ["", "12345", "1234567", "１２３４５６", "12345x", "123 56"] {
    #expect(throws: PairingError.invalidCode) { try ADBPairing.validateCode(code) }
  }
  let transport = PairingBytes(Data([1, 1, 0, 0, 0, 32]))
  await #expect(throws: PairingError.invalidPacket) {
    try await ADBPairing.exchange(
      transport: transport, exporter: Data(repeating: 0, count: 64), code: "123456",
      publicKey: Data("key\0".utf8))
  }
  let short = PairingBytes(Data([1, 0, 0]))
  await #expect(throws: RemoteError.notConnected) {
    try await ADBPairing.exchange(
      transport: short, exporter: Data(repeating: 0, count: 64), code: "123456",
      publicKey: Data("key\0".utf8))
  }
}
