import Foundation

enum WebLoginCredentialParser {
  static func authorization(
    _ value: String, service: WebLoginService, phone: String? = nil, userDomainID: String? = nil
  ) -> WebLoginCredentials? {
    guard safe(value) else { return nil }
    switch service {
    case .mobile:
      guard value.lowercased().hasPrefix("basic ") else { return nil }
      let token = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      guard !token.isEmpty, let decoded = Data(base64Encoded: token),
        let text = String(data: decoded, encoding: .utf8)
      else { return nil }
      let pieces = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard pieces.count == 3, pieces[0] == "pc", !pieces[1].isEmpty, !pieces[2].isEmpty else {
        return nil
      }
      let account = String(pieces[1])
      guard safe(account), phone.map({ $0.isEmpty || $0 == account }) ?? true else { return nil }
      return WebLoginCredentials(
        phone: account, token: token,
        userDomainID: userDomainID.flatMap { safe($0) && !$0.isEmpty ? $0 : nil })
    case .xunlei:
      guard value.lowercased().hasPrefix("token ") else { return nil }
      let token = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
      return WebLoginCredentials(token: token)
    default: return nil
    }
  }

  static func cookies(_ cookies: [HTTPCookie], service: WebLoginService, now: Date = Date())
    -> WebLoginCredentials?
  {
    guard let host = service.loginURL.host else { return nil }
    var values: [String: String] = [:]
    for cookie in cookies.sorted(by: { $0.domain.count < $1.domain.count }) {
      let domain = cookie.domain.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
      guard host == domain || host.hasSuffix("." + domain),
        cookie.expiresDate.map({ $0 > now }) ?? true,
        !cookie.value.isEmpty, safe(cookie.name), safe(cookie.value), !cookie.name.contains(";"),
        !cookie.value.contains(";")
      else { continue }
      values[cookie.name] = cookie.value
    }
    switch service {
    case .quark, .uc:
      guard values["__pus"] != nil, values["__puus"] != nil else { return nil }
    case .lanzou:
      guard values["phpdisk_info"] != nil || values["phpdisk_zinfo"] != nil else { return nil }
    case .tianyi:
      guard !values.isEmpty else { return nil }
    case .mobile, .xunlei: return nil
    }
    let header = values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; ")
    return WebLoginCredentials(cookie: header)
  }

  static func manual(
    _ value: String, service: WebLoginService, phone: String = "", userDomainID: String = ""
  ) -> WebLoginCredentials? {
    var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = service == .mobile || service == .xunlei ? "authorization:" : "cookie:"
    if value.lowercased().hasPrefix(prefix) {
      value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    guard !value.isEmpty, safe(value) else { return nil }
    switch service {
    case .mobile:
      return authorization(
        value.lowercased().hasPrefix("basic ") ? value : "Basic " + value, service: service,
        phone: phone, userDomainID: userDomainID)
    case .xunlei:
      return authorization(
        value.lowercased().hasPrefix("token ") ? value : "Token " + value, service: service)
    default:
      return WebLoginCredentials(cookie: value)
    }
  }

  private static func safe(_ value: String) -> Bool {
    !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
