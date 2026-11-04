import Core
import CoreFoundation
import Foundation

struct LanzouCookieHeader: Equatable, Sendable {
  private var values: [String: String]

  init(_ header: String) throws {
    guard Self.isSafe(header) else { throw LanzouError.invalidConfiguration }
    var parsed: [String: String] = [:]
    for part in header.split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw LanzouError.invalidConfiguration }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, Self.isToken(name) else {
        throw LanzouError.invalidConfiguration
      }
      parsed[name] = value
    }
    values = parsed
  }

  var text: String {
    values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
  }

  mutating func merge(_ response: HTTPResponse, from requestURL: URL) {
    let responseURL = response.url ?? requestURL
    guard let raw = response.header("Set-Cookie") else { return }
    for cookie in HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": raw], for: responseURL)
    {
      guard Self.accepts(cookie, for: responseURL) else { continue }
      let maxAge = cookie.properties?[.maximumAge].flatMap { String(describing: $0) }
        .flatMap(Int.init)
      if cookie.expiresDate.map({ $0 <= Date() }) == true || maxAge.map({ $0 <= 0 }) == true {
        values.removeValue(forKey: cookie.name)
      } else {
        values[cookie.name] = cookie.value
      }
    }
  }

  mutating func add(_ name: String, value: String) {
    values[name] = value
  }

  static func isSafe(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7f) }
  }

  private static func isToken(_ value: String) -> Bool {
    let allowed = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
    return !value.isEmpty && value.utf8.allSatisfy { allowed.contains($0) }
  }

  private static func accepts(_ cookie: HTTPCookie, for url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host == domain || host.hasSuffix("." + domain)
  }
}

enum LanzouValues {
  // 显示用的 KB、MB 可能已取整，不能代替实际字节数。
  static func parseSize(_ value: Any?) -> Int64? {
    let text: String
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      text = number.stringValue
    } else if let string = value as? String {
      text = string
    } else {
      return nil
    }
    guard let match = LanzouHTML.firstMatch(#"(?i)^\s*([0-9]+)\s*(?:B|字节)?\s*$"#, in: text),
      let digits = match[1]
    else { return nil }
    return Int64(digits)
  }

  static func parseDate(_ value: String?) -> Date {
    guard let value, !value.isEmpty else { return Date(timeIntervalSince1970: 0) }
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: value) { return date }
    guard let match = LanzouHTML.firstMatch(#"([0-9]+)\s*([秒分小]|小时|分钟|天)前"#, in: value),
      let numberText = match[1], let number = Double(numberText)
    else {
      if value.contains("昨天") { return Date().addingTimeInterval(-86_400) }
      if value.contains("前天") { return Date().addingTimeInterval(-172_800) }
      return Date(timeIntervalSince1970: 0)
    }
    let seconds =
      number
      * (match[2] == "秒"
        ? 1
        : match[2] == "分" || match[2] == "分钟"
          ? 60 : match[2] == "小" || match[2] == "小时" ? 3600 : 86_400)
    return Date().addingTimeInterval(-seconds)
  }

  static func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }
}

struct LanzouHTMLMatch {
  private let groups: [String?]

  init(_ groups: [String?]) {
    self.groups = groups
  }

  subscript(index: Int) -> String? {
    guard groups.indices.contains(index) else { return nil }
    return groups[index]
  }
}

enum LanzouHTML {
  static func firstMatch(_ pattern: String, in text: String) -> LanzouHTMLMatch? {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: range) else { return nil }
    return LanzouHTMLMatch(
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      })
  }

  static func allMatches(_ pattern: String, in text: String) -> [[String?]] {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).map { match in
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
    }
  }

  static func variables(in html: String) -> [String: String] {
    let matches = allMatches(
      #"(?i)\b(?:var|let|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*['"]([^'"]*)['"]\s*"#,
      in: html)
    return matches.reduce(into: [:]) { result, match in
      if let name = match[safe: 1] ?? nil, let value = match[safe: 2] ?? nil {
        result[name] = value
      }
    }
  }

  static func keyValueObject(in html: String, variables: [String: String]) -> [String: String] {
    let body: String
    if let object = firstMatch(#"data\s*:\s*\{([^}]*)\}"#, in: html), let value = object[1] {
      body = value
    } else if let encoded = firstMatch(
      #"data\s*:\s*(?:'([^']+)'|"([^"]+)")"#, in: html),
      let text = encoded[1] ?? encoded[2],
      let decoded = text.removingPercentEncoding
    {
      if let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8))
        as? [String: Any]
      {
        return object.reduce(into: [:]) { result, pair in
          if let value = LanzouValues.string(pair.value) { result[pair.key] = value }
        }
      }
      if decoded.contains("=") {
        return decoded.split(separator: "&").reduce(into: [:]) { result, pair in
          let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          if parts.count == 2 {
            result[String(parts[0])] = String(parts[1])
          }
        }
      }
      return [:]
    } else {
      return [:]
    }

    let pairs = allMatches(
      #"['"]([^'"]+)['"]\s*:\s*(?:['"]([^'"]*)['"]|([A-Za-z_$][A-Za-z0-9_$]*))"#, in: body)
    return pairs.reduce(into: [:]) { result, match in
      guard let key = match[safe: 1] ?? nil else { return }
      if let literal = match[safe: 2] ?? nil {
        result[key] = literal
      } else if let variable = match[safe: 3] ?? nil, let value = variables[variable] {
        result[key] = value
      }
    }
  }

  static func strippedText(_ html: String) -> String {
    text(html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
  }

  static func text(_ html: String) -> String {
    var output = html
    let replacements = [
      "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
      "&#x1F431;": "🐱",
    ]
    for (source, target) in replacements {
      output = output.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
    }
    if let expression = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) {
      let original = output
      let range = NSRange(original.startIndex..., in: original)
      for match in expression.matches(in: original, range: range).reversed() {
        guard let whole = Range(match.range(at: 0), in: original),
          let digits = Range(match.range(at: 1), in: original)
        else { continue }
        let value = String(original[digits])
        let radix = value.lowercased().hasPrefix("x") ? 16 : 10
        let numberText = radix == 16 ? String(value.dropFirst()) : value
        if let scalar = UInt32(numberText, radix: radix), let unicode = UnicodeScalar(scalar) {
          output.replaceSubrange(whole, with: String(Character(unicode)))
        }
      }
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Array where Element == String? {
  subscript(safe index: Int) -> String?? {
    indices.contains(index) ? self[index] : nil
  }
}
