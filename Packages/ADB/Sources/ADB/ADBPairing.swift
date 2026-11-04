import BoringCrypto
import Core
import CryptoKit
import Foundation
import Network

public enum PairingError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidCode, wrongCode, invalidPacket
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    switch self {
    case .invalidCode: Int(EINVAL)
    case .wrongCode: Int(EACCES)
    case .invalidPacket: Int(EIO)
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
  public var errorDescription: String? {
    switch self {
    case .invalidCode: L("请输入 6 位配对码")
    case .wrongCode: L("配对码错误")
    case .invalidPacket: L("手机返回了无效的配对数据")
    }
  }
}

struct PairingHeader: Equatable {
  enum Kind: UInt8 {
    case spake = 0
    case peerInfo = 1
  }
  let kind: Kind
  let length: Int
  init(kind: Kind, length: Int) throws {
    guard (1...16_384).contains(length) else { throw PairingError.invalidPacket }
    self.kind = kind
    self.length = length
  }
  init(_ data: Data) throws {
    let bytes = Array(data)
    guard bytes.count == 6, bytes[0] == 1, let kind = Kind(rawValue: bytes[1]) else {
      throw PairingError.invalidPacket
    }
    let length = bytes.dropFirst(2).reduce(0) { ($0 << 8) | Int($1) }
    try self.init(kind: kind, length: length)
  }
  var encoded: Data {
    Data([
      1, kind.rawValue, UInt8(truncatingIfNeeded: length >> 24),
      UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8),
      UInt8(truncatingIfNeeded: length),
    ])
  }
}

final class PairingSPAKE {
  private let context: UnsafeMutableRawPointer
  private var processed = false
  let message: Data
  init(password: Data, server: Bool = false) throws {
    guard !password.isEmpty, let context = kayoi_spake_new(server ? 1 : 0) else {
      throw PairingError.invalidPacket
    }
    var output = Data(count: 32)
    var length = 0
    let result = output.withUnsafeMutableBytes { bytes in
      password.withUnsafeBytes { input in
        kayoi_spake_message(
          context, input.bindMemory(to: UInt8.self).baseAddress, password.count,
          bytes.bindMemory(to: UInt8.self).baseAddress, &length, 32)
      }
    }
    guard result == 1, length == 32 else {
      kayoi_spake_free(context)
      throw PairingError.invalidPacket
    }
    self.context = context
    message = output
  }
  deinit { kayoi_spake_free(context) }
  func sharedKey(peer: Data) throws -> Data {
    guard !processed, peer.count == 32 else { throw PairingError.invalidPacket }
    processed = true
    var output = Data(count: 64)
    var length = 0
    let result = output.withUnsafeMutableBytes { bytes in
      peer.withUnsafeBytes { input in
        kayoi_spake_key(
          context, input.bindMemory(to: UInt8.self).baseAddress, peer.count,
          bytes.bindMemory(to: UInt8.self).baseAddress, &length, 64)
      }
    }
    guard result == 1, length > 0, length <= 64 else { throw PairingError.wrongCode }
    return Data(output.prefix(length))
  }
}

struct PairingCipher {
  private let key: SymmetricKey
  private var encryptedSequence: UInt64 = 0
  private var decryptedSequence: UInt64 = 0
  init(material: Data) {
    key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: material), salt: Data(),
      info: Data("adb pairing_auth aes-128-gcm key".utf8), outputByteCount: 16)
  }
  private func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
    var bytes = Data(repeating: 0, count: 12)
    for index in 0..<8 { bytes[index] = UInt8(truncatingIfNeeded: sequence >> (index * 8)) }
    return try AES.GCM.Nonce(data: bytes)
  }
  mutating func encrypt(_ data: Data) throws -> Data {
    guard encryptedSequence < UInt64.max else { throw PairingError.invalidPacket }
    let box = try AES.GCM.seal(data, using: key, nonce: nonce(encryptedSequence))
    encryptedSequence += 1
    return box.ciphertext + box.tag
  }
  mutating func decrypt(_ data: Data) throws -> Data {
    guard data.count >= 16, decryptedSequence < UInt64.max else { throw PairingError.invalidPacket }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: nonce(decryptedSequence),
        ciphertext: Data(data.dropLast(16)), tag: Data(data.suffix(16)))
      let clear = try AES.GCM.open(box, using: key)
      decryptedSequence += 1
      return clear
    } catch { throw PairingError.wrongCode }
  }
}

public enum ADBPairing {
  public static func pair(
    host: String, port: UInt16, code: String,
    identity: ADBIdentity = ADBIdentity()
  ) async throws -> String {
    try validateCode(code)
    guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else {
      throw RemoteError.invalidPath
    }
    let transport = try NetworkTransport(
      endpoint: .hostPort(host: .init(host), port: port),
      startTLS: false, identity: identity)
    do {
      try await transport.start()
      let guid = try await exchange(
        transport: transport, exporter: transport.exporter(),
        code: code, publicKey: identity.publicKeyLine())
      await transport.close()
      return guid
    } catch {
      await transport.close()
      throw error
    }
  }

  static func validateCode(_ code: String) throws {
    guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
      throw PairingError.invalidCode
    }
  }

  // AOSP pairing_connection 的帧和 PeerInfo；TLS exporter 不含在网络负载中。
  static func exchange(
    transport: any ADBTransport, exporter: Data, code: String,
    publicKey: Data
  ) async throws -> String {
    try validateCode(code)
    guard exporter.count == 64, !publicKey.isEmpty, publicKey.count < 8191 else {
      throw PairingError.invalidPacket
    }
    let spake = try PairingSPAKE(password: Data(code.utf8) + exporter)
    try await send(.spake, payload: spake.message, transport: transport)
    let message = try await receive(.spake, transport: transport)
    var cipher = PairingCipher(material: try spake.sharedKey(peer: message))
    var peer = Data(repeating: 0, count: 8192)
    peer.replaceSubrange(1..<(1 + publicKey.count), with: publicKey)
    try await send(.peerInfo, payload: cipher.encrypt(peer), transport: transport)
    let encrypted = try await receive(.peerInfo, transport: transport)
    let reply = try cipher.decrypt(encrypted)
    guard reply.count == 8192, reply.first == 1,
      let end = reply.dropFirst().firstIndex(of: 0), end > 1,
      let guid = String(data: reply.subdata(in: 1..<end), encoding: .utf8), !guid.isEmpty
    else {
      throw PairingError.invalidPacket
    }
    return guid
  }

  private static func send(
    _ kind: PairingHeader.Kind, payload: Data,
    transport: any ADBTransport
  ) async throws {
    let header = try PairingHeader(kind: kind, length: payload.count)
    try await transport.write(header.encoded + payload, timeout: RemoteTimeout.deviceRequest)
  }
  private static func readExactly(_ count: Int, transport: any ADBTransport) async throws -> Data {
    var result = Data()
    let end = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    while result.count < count {
      let remaining = ContinuousClock.now.duration(to: end)
      let seconds =
        Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
      guard seconds > 0 else { throw RemoteError.posix(ETIMEDOUT) }
      let data = try await transport.read(count: count - result.count, timeout: seconds)
      guard !data.isEmpty, data.count <= count - result.count else {
        throw PairingError.invalidPacket
      }
      result.append(data)
    }
    return result
  }
  private static func receive(
    _ expected: PairingHeader.Kind,
    transport: any ADBTransport
  ) async throws -> Data {
    let header = try PairingHeader(await readExactly(6, transport: transport))
    guard header.kind == expected else { throw PairingError.invalidPacket }
    return try await readExactly(header.length, transport: transport)
  }
}
