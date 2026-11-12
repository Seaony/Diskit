import Foundation

enum UpdatePolicy {
  static let feedURL = URL(
    string: "https://github.com/Seaony/Diskit/releases/latest/download/appcast.xml")!
  static let publicKey = "FnPUWAEY6WKwo0yvQLOBvEt7xjuhAabwNu1Y9QalNQc="

  static func shouldStart(isDemo: Bool, bundleURL: URL, environment: [String: String]) -> Bool {
    !isDemo && bundleURL.pathExtension == "app"
      && environment["XCTestConfigurationFilePath"] == nil
      && environment["XCTestBundlePath"] == nil
      && environment["SWIFT_TESTING_ENABLED"] != "1"
  }

  static func isMissingFeed(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    var visited = Set<ObjectIdentifier>()
    while let value = current, visited.insert(ObjectIdentifier(value)).inserted {
      // Sparkle 2.10.1 的下载错误用末尾 HTTP 状态码标识。
      if value.domain == "SUSparkleErrorDomain", value.code == 2001,
        value.localizedDescription.hasSuffix("(404)")
      {
        return true
      }
      current = value.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}
