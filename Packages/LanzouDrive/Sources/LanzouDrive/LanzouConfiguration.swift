import Foundation

public enum LanzouAuthentication: Equatable, Sendable {
  case accountCookie(String)
  case share(url: URL, password: String?)
}

public struct LanzouConfiguration: Equatable, Sendable {
  public static let defaultAccountBaseURL = URL(string: "https://pc.woozooo.com")!
  public static let defaultShareBaseURL = URL(string: "https://pan.lanzoui.com")!
  public static let defaultUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

  public let authentication: LanzouAuthentication
  public let accountBaseURL: URL
  public let shareBaseURL: URL
  public let userAgent: String

  public init(
    authentication: LanzouAuthentication,
    accountBaseURL: URL = Self.defaultAccountBaseURL,
    shareBaseURL: URL = Self.defaultShareBaseURL,
    userAgent: String = Self.defaultUserAgent
  ) throws {
    guard Self.isHTTPSOrigin(accountBaseURL), Self.isHTTPSOrigin(shareBaseURL),
      !userAgent.isEmpty
    else {
      throw LanzouError.invalidConfiguration
    }
    switch authentication {
    case .accountCookie(let cookie):
      guard LanzouCookieHeader.isSafe(cookie), !cookie.isEmpty else {
        throw LanzouError.invalidConfiguration
      }
    case .share(let url, _):
      guard Self.isHTTPSURL(url), url.path.count > 1 else {
        throw LanzouError.invalidConfiguration
      }
    }
    self.authentication = authentication
    self.accountBaseURL = accountBaseURL
    self.shareBaseURL = shareBaseURL
    self.userAgent = userAgent
  }

  static func isHTTPSURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
  }

  static func isHTTPSOrigin(_ url: URL) -> Bool {
    isHTTPSURL(url)
      && (url.path.isEmpty || url.path == "/")
      && url.query == nil
      && url.fragment == nil
  }
}
