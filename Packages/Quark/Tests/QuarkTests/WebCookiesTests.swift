import Foundation
import Testing

@testable import Quark

private func webCookie(
  _ name: String, _ value: String, domain: String = ".quark.cn", expired: Bool = false
) throws -> HTTPCookie {
  try #require(
    HTTPCookie(properties: [
      .name: name, .value: value, .domain: domain, .path: "/",
      .expires: Date().addingTimeInterval(expired ? -60 : 3600),
    ]))
}

@Test func webCookiesRequireLoginPairAndExcludeOtherDomainsAndExpiredValues() throws {
  let puus = try webCookie("__puus", "test-puus")
  #expect(QuarkWebCookies.header(from: [puus]) == nil)
  #expect(
    try QuarkWebCookies.header(from: [puus, webCookie("__pus", "old", expired: true)]) == nil)
  let header = try QuarkWebCookies.header(from: [
    puus, webCookie("__pus", "test-pus"),
    webCookie("external", "private", domain: "quark.cn.attacker.invalid"),
    webCookie("lookalike", "private", domain: "evilquark.cn"),
  ])
  #expect(header == "__pus=test-pus; __puus=test-puus")
}
