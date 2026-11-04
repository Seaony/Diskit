import Foundation
import Testing

@testable import Quark

private let cookieNow = Date(timeIntervalSince1970: 1_700_000_000)

private func webCookie(
  _ name: String, _ value: String, domain: String = ".quark.cn", expired: Bool = false
) throws -> HTTPCookie {
  try #require(
    HTTPCookie(properties: [
      .name: name, .value: value, .domain: domain, .path: "/",
      .expires: cookieNow.addingTimeInterval(expired ? -60 : 3600),
    ]))
}

@Test func webCookiesRequireLoginPairAndExcludeOtherDomainsAndExpiredValues() throws {
  let puus = try webCookie("__puus", "test-puus")
  #expect(QuarkWebCookies.header(from: [puus], now: cookieNow) == nil)
  #expect(
    try QuarkWebCookies.header(from: [puus, webCookie("__pus", "old", expired: true)], now: cookieNow) == nil)
  let header = try QuarkWebCookies.header(from: [
    puus, webCookie("__pus", "test-pus"),
    webCookie("external", "private", domain: "quark.cn.attacker.invalid"),
    webCookie("lookalike", "private", domain: "evilquark.cn"),
  ], now: cookieNow)
  #expect(header == "__pus=test-pus; __puus=test-puus")

  let uc = try QuarkWebCookies.header(
    from: [
      webCookie("__puus", "uc-puus", domain: ".uc.cn"),
      webCookie("__pus", "uc-pus", domain: ".uc.cn"),
      webCookie("quark", "ignored"),
    ], domain: "uc.cn", now: cookieNow)
  #expect(uc == "__pus=uc-pus; __puus=uc-puus")
}
