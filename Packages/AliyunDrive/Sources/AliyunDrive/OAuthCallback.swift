import Core
import Foundation

public enum OAuthCallbackError: Error, LocalizedError {
  case invalid, declined
  public var errorDescription: String? {
    switch self {
    case .invalid: L("授权回调不匹配，请重新登录")
    case .declined: L("授权未完成，请重试")
    }
  }
}

public enum OAuthCallback {
  public static func code(from callback: URL, redirectURI: String, state: String) throws -> String {
    guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      let expected = URLComponents(string: redirectURI),
      actual.scheme == expected.scheme, actual.host == expected.host,
      actual.port == expected.port, actual.path == expected.path
    else { throw OAuthCallbackError.invalid }
    func single(_ key: String) -> String? {
      let values = (actual.queryItems ?? []).filter { $0.name == key }
      return values.count == 1 ? values[0].value : nil
    }
    guard !state.isEmpty, single("state") == state else { throw OAuthCallbackError.invalid }
    if (actual.queryItems ?? []).contains(where: { $0.name == "error" }) {
      throw OAuthCallbackError.declined
    }
    guard let code = single("code"), !code.isEmpty else { throw OAuthCallbackError.invalid }
    return code
  }
}
