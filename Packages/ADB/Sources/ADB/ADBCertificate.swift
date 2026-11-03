import Core
import CryptoKit
import Foundation
import Security

// 这里只编码证书结构，签名由 Security 完成。
enum DER {
  static func node(_ tag: UInt8, _ content: Data) -> Data {
    var length = Data()
    if content.count < 128 {
      length.append(UInt8(content.count))
    } else {
      var value = content.count
      var bytes: [UInt8] = []
      while value > 0 {
        bytes.insert(UInt8(value & 255), at: 0)
        value >>= 8
      }
      length.append(0x80 | UInt8(bytes.count))
      length.append(contentsOf: bytes)
    }
    return Data([tag]) + length + content
  }
  static func sequence(_ content: Data) -> Data { node(0x30, content) }
  static func oid(_ bytes: [UInt8]) -> Data { node(6, Data(bytes)) }
}

extension ADBIdentity {
  public func tlsIdentity() throws -> sec_identity_t {
    let key = try securityKey()
    guard let publicKey = SecKeyCopyPublicKey(key) else { throw RemoteError.protocolError }
    var error: Unmanaged<CFError>?
    guard let exported = SecKeyCopyExternalRepresentation(publicKey, &error) else {
      throw RemoteError.protocolError
    }
    let publicDER = exported as Data
    let algorithm = DER.sequence(
      DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]) + Data([5, 0]))
    let name = DER.sequence(
      DER.node(0x31, DER.sequence(DER.oid([0x55, 4, 3]) + DER.node(0x0c, Data("Adb".utf8)))))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    let now = Date()
    let validity = DER.sequence(
      DER.node(0x17, Data(formatter.string(from: now.addingTimeInterval(-60)).utf8))
        + DER.node(
          0x17, Data(formatter.string(from: now.addingTimeInterval(10 * 365 * 86_400)).utf8)))
    let spki = DER.sequence(
      DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]) + Data([5, 0]))
        + DER.node(3, Data([0]) + publicDER))
    let constraints = DER.sequence(
      DER.oid([0x55, 0x1d, 0x13]) + Data([1, 1, 0xff])
        + DER.node(4, DER.sequence(Data([1, 1, 0xff]))))
    let usage = DER.sequence(
      DER.oid([0x55, 0x1d, 0x0f]) + Data([1, 1, 0xff]) + DER.node(4, DER.node(3, Data([1, 0x86]))))
    let subjectKey = DER.sequence(
      DER.oid([0x55, 0x1d, 0x0e])
        + DER.node(4, DER.node(4, Data(Insecure.SHA1.hash(data: publicDER)))))
    let tbs = DER.sequence(
      DER.node(0xa0, Data([2, 1, 2])) + Data([2, 1, 1]) + algorithm + name + validity + name + spki
        + DER.node(0xa3, DER.sequence(constraints + usage + subjectKey)))
    guard
      let signature = SecKeyCreateSignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error)
    else { throw RemoteError.protocolError }
    let data = DER.sequence(tbs + algorithm + DER.node(3, Data([0]) + (signature as Data)))
    guard let certificate = SecCertificateCreateWithData(nil, data as CFData),
      let identity = SecIdentityCreate(nil, certificate, key),
      let result = sec_identity_create(identity)
    else { throw RemoteError.protocolError }
    return result
  }
}
