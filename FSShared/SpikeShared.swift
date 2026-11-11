import Foundation
import Security

/// 主 App 和扩展共用的验证常量：App Group 和共享钥匙串访问组。
enum SpikeShared {
  static let teamID = "JJJKGPY7T7"
  static let appGroup = "\(teamID).com.seaony.Kayoi"
  static let keychainGroup = "\(teamID).com.seaony.Kayoi.shared"
  static let keychainService = "com.seaony.Kayoi.spike"
  static let fileName = "spike-check.txt"

  static var groupFile: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: fileName)
  }

  static func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "check",
      kSecAttrAccessGroup as String: keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  /// 读共享钥匙串里的验证条目，返回内容或错误码。
  static func readKeychain() -> String {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return "读取失败 OSStatus \(status)" }
    return String(decoding: data, as: UTF8.self)
  }

  /// 读 App Group 里的验证文件，返回内容或错误。
  static func readGroupFile() -> String {
    guard let url = groupFile else { return "拿不到 App Group 容器" }
    do { return try String(contentsOf: url, encoding: .utf8) } catch { return "读取失败 \(error.localizedDescription)" }
  }
}
