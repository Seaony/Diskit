import Core
import Foundation

struct QuarkCookie {
  var values: [String: String]
  init(_ header: String) throws {
    guard !header.isEmpty, header.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else {
      throw QuarkError.invalidCookie
    }
    let allowed = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
    var values: [String: String] = [:]
    for item in header.split(separator: ";") {
      let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { throw QuarkError.invalidCookie }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else {
        throw QuarkError.invalidCookie
      }
      values[name] = value
    }
    self.values = values
  }
  var valid: Bool { !(values["__puus"] ?? "").isEmpty && !(values["__pus"] ?? "").isEmpty }
  var header: String { values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; ") }
  func merging(_ response: HTTPResponse, from url: URL, cookieDomain: String) -> QuarkCookie {
    let sourceURL = response.url ?? url
    guard QuarkSession.trusted(sourceURL, domain: cookieDomain),
      let value = response.header("Set-Cookie")
    else {
      return self
    }
    var result = self
    let incoming = HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": value], for: sourceURL)
    let host = sourceURL.host?.lowercased() ?? ""
    for cookie in incoming {
      let domain = cookie.domain.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
      guard domain == cookieDomain || domain.hasSuffix("." + cookieDomain),
        host == domain || host.hasSuffix("." + domain)
      else { continue }
      let maxAge = cookie.properties?[.maximumAge].map { String(describing: $0) }.flatMap(Int.init)
      if cookie.expiresDate.map({ $0 <= Date() }) == true || maxAge.map({ $0 <= 0 }) == true {
        result.values.removeValue(forKey: cookie.name)
      } else {
        result.values[cookie.name] = cookie.value
      }
    }
    return result
  }
}
