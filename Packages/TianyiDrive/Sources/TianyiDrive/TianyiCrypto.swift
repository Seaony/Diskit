import CommonCrypto
import CryptoKit
import Foundation

enum TianyiCrypto {
  static func signature(
    sessionSecret: String, sessionKey: String, operate: String, path: String, date: String,
    params: String?
  ) -> String {
    var value =
      "SessionKey=\(sessionKey)&Operate=\(operate.uppercased())"
      + "&RequestURI=\(path)&Date=\(date)"
    if let params, !params.isEmpty {
      value += "&params=\(params)"
    }
    let code = HMAC<Insecure.SHA1>.authenticationCode(
      for: Data(value.utf8), using: SymmetricKey(data: Data(sessionSecret.utf8)))
    return Data(code).map { String(format: "%02X", $0) }.joined()
  }

  static func encryptedParameters(
    _ parameters: [String: String], sessionSecret: String
  ) throws -> String {
    guard sessionSecret.count >= 16 else { throw TianyiError.invalidResponse }
    let sorted = parameters.keys.sorted().map { $0 + "=" + (parameters[$0] ?? "") }.joined(
      separator: "&")
    let key = String(sessionSecret.prefix(16))
    return try aesECBHex(Data(sorted.utf8), key: key)
  }

  static func md5Hex(_ data: Data) -> String {
    Data(Insecure.MD5.hash(data: data)).map { String(format: "%02X", $0) }.joined()
  }

  static func md5Base64(_ data: Data) -> String {
    Data(Insecure.MD5.hash(data: data)).base64EncodedString()
  }

  private static func aesECBHex(_ data: Data, key: String) throws -> String {
    let keyBytes = Array(key.utf8)
    guard keyBytes.count == kCCKeySizeAES128 else { throw TianyiError.invalidResponse }
    let input = Array(data)
    var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var moved = 0
    let outputCount = output.count
    let status = input.withUnsafeBytes { inputBuffer in
      keyBytes.withUnsafeBytes { keyBuffer in
        output.withUnsafeMutableBytes { outputBuffer in
          CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), keyBuffer.baseAddress,
            keyBytes.count, nil, inputBuffer.baseAddress, input.count,
            outputBuffer.baseAddress, outputCount, &moved)
        }
      }
    }
    guard status == kCCSuccess else { throw TianyiError.invalidResponse }
    output.removeSubrange(moved..<output.count)
    return output.map { String(format: "%02X", $0) }.joined()
  }
}
