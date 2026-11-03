import Foundation

public enum QuarkWebCookies {
  public static func header(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
    var values: [String: String] = [:]
    for cookie in cookies.sorted(by: { $0.domain.count < $1.domain.count }) {
      let domain = cookie.domain.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
      guard domain == "quark.cn" || domain.hasSuffix(".quark.cn"),
        cookie.expiresDate.map({ $0 > now }) ?? true,
        !cookie.value.isEmpty
      else { continue }
      values[cookie.name] = cookie.value
    }
    guard values["__puus"] != nil, values["__pus"] != nil else { return nil }
    return values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; ")
  }
}
