import Core
import Foundation

enum SettingsLicense: String, Identifiable {
  case notices
  case apache
  var id: String { rawValue }
  var title: String {
    switch self {
    case .notices: L("致谢与许可证")
    case .apache: L("Apache 2.0 许可证")
    }
  }
  var resourceName: String {
    switch self {
    case .notices: "THIRD_PARTY_NOTICES"
    case .apache: "Apache-2.0"
    }
  }
  var resourceExtension: String { self == .notices ? "md" : "txt" }

  func resourceURL(in bundle: Bundle = .main) -> URL? {
    bundle.url(forResource: resourceName, withExtension: resourceExtension)
  }

  static func read(at url: URL?) throws -> String {
    guard let url else { throw SettingsLicenseError.missingResource }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

enum SettingsLicenseError: Error, LocalizedError {
  case missingResource
  var errorDescription: String? { L("没有找到应用内的许可证文件，请重新安装 Kayoi 后重试。") }
}
