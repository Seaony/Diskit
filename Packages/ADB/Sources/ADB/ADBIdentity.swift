import BoringCrypto
import Core
import CryptoKit
import Foundation
import Security

public struct ADBIdentity: Sendable {
  private static let keyLock = NSLock()
  private let store: any SecretStore
  public init(store: any SecretStore = LoginKeychainStore()) { self.store = store }
  func key(regenerate: Bool = false) throws -> SecKey {
    Self.keyLock.lock()
    defer { Self.keyLock.unlock() }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048,
    ]
    var error: Unmanaged<CFError>?
    if !regenerate, let existing = try store.read("adb.private-key") {
      guard let key = SecKeyCreateWithData(existing as CFData, attributes as CFDictionary, &error)
      else { throw error!.takeRetainedValue() }
      return key
    }
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
      let bytes = SecKeyCopyExternalRepresentation(key, &error)
    else { throw error!.takeRetainedValue() }
    try store.write(bytes as Data, for: "adb.private-key")
    return key
  }
  func securityKey() throws -> SecKey { try key() }
  public func regenerate() throws { _ = try key(regenerate: true) }
  public func sign(_ token: Data) throws -> Data {
    guard token.count == 20 else { throw RemoteError.protocolError }
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        try key(), .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error)
    else { throw error!.takeRetainedValue() }
    return signature as Data
  }
  public func publicKeyData() throws -> Data {
    var error: Unmanaged<CFError>?
    guard let publicKey = SecKeyCopyPublicKey(try key()),
      let exported = SecKeyCopyExternalRepresentation(publicKey, &error)
    else { throw RemoteError.protocolError }
    return try Self.encode(publicDER: exported as Data)
  }
  public static func encode(publicDER: Data) throws -> Data {
    var encoded = Data(count: 524)
    let result = encoded.withUnsafeMutableBytes { out in
      publicDER.withUnsafeBytes { input in
        kayoi_android_public_key(
          input.bindMemory(to: UInt8.self).baseAddress, publicDER.count,
          out.bindMemory(to: UInt8.self).baseAddress, 524)
      }
    }
    guard result == 1 else { throw RemoteError.protocolError }
    return encoded
  }
  public func publicKeyLine() throws -> Data {
    let comment = "kayoi@mac"
    return Data((try publicKeyData().base64EncodedString() + " " + comment + "\0").utf8)
  }
  public func fingerprint() throws -> String {
    Self.fingerprint(publicKeyData: try publicKeyData())
  }
  static func fingerprint(publicKeyData: Data) -> String {
    // 与手机授权窗口的公钥摘要保持一致。
    Insecure.MD5.hash(data: publicKeyData).map { String(format: "%02X", $0) }.joined(separator: ":")
  }
}
