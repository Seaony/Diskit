import Core
import CoreTestSupport
import Foundation
import Testing

@testable import ChinaWebDrive

private func sessionResponse(_ text: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(text.utf8))
}
private let coverageRoute = sessionResponse(
  #"{"data":{"routePolicyList":[{"modName":"personal","httpsUrl":"https://personal.yun.139.com/hcy","hashName":"sha1"}]}}"#
)

@Test func mobileSessionRefreshesRouteAndAccountWithoutReplayingForever() async throws {
  let transport = ScriptedHTTPTransport([
    sessionResponse(#"{"code":"9008"}"#, status: 401), coverageRoute,
    sessionResponse(#"{"code":9008}"#), sessionResponse(#"{"code":0}"#),
    sessionResponse(#"{"code":9008}"#), sessionResponse(#"{"code":9008}"#),
  ])
  let session = MobileCloudSession(
    credentials: .init(phone: "phone", token: "old", userDomainID: "domain"),
    refresh: { old in .init(phone: old.phone, token: old.token + "next", userDomainID: "domain") },
    transport: transport)
  try await session.connect()
  #expect(await session.hashAlgorithm == "sha1")
  #expect(await session.userDomainID == "domain")
  _ = try await session.accountRequest("/account", body: [:])
  await #expect(throws: MobileCloudError.loginRequired) {
    _ = try await session.accountRequest("/account", body: [:])
  }
  #expect(transport.requests.withLock { $0.count } == 6)
  await session.disconnect()
  #expect(await session.hashAlgorithm == "sha256")
  await #expect(throws: MobileCloudError.invalidResponse) {
    _ = try await session.request("files", body: [:])
  }
}

@Test func mobileSessionFallsBackOnlyWhenRouteIsMissing() async throws {
  let transport = ScriptedHTTPTransport([
    coverageRoute, sessionResponse(#"{"message":"route not found"}"#, status: 404),
    sessionResponse(#"{"code":0}"#),
    sessionResponse(#"{"code":"9000","message":"quota exceeded"}"#),
  ])
  let session = MobileCloudSession(
    credentials: .init(phone: "phone", token: "token"), transport: transport)
  try await session.connect()
  _ = try await session.request("files", body: [:])
  let paths = transport.requests.withLock { $0.compactMap { $0.url?.path } }
  #expect(paths.suffix(2) == ["/hcy/files", "/orchestration/files"])
  await #expect(throws: RemoteError.posix(ENOSPC)) {
    _ = try await session.request("files", body: [:])
  }
  #expect(transport.requests.withLock { $0.count } == 4)
}

@Test(arguments: ["empty", "throw"])
func mobileRefreshFailureDoesNotRetainBrokenTask(mode: String) async throws {
  let transport = ScriptedHTTPTransport([
    coverageRoute, sessionResponse("{}", status: 401), sessionResponse("{}", status: 401),
  ])
  let session = MobileCloudSession(
    credentials: .init(phone: "phone", token: "token"),
    refresh: { _ in
      if mode == "throw" { throw URLError(.notConnectedToInternet) }
      return .init(phone: "", token: "")
    }, transport: transport)
  try await session.connect()
  for _ in 0..<2 {
    do {
      _ = try await session.accountRequest("account", body: [:])
      Issue.record("刷新失败应传播")
    } catch {
      #expect((error as NSError).code == (mode == "throw" ? Int(ENETUNREACH) : Int(EACCES)))
    }
  }
  #expect(transport.requests.withLock { $0.count } == 3)
}

@Test func mobileRejectsInvalidLocalCredentialsNonceAndDownloadURL() async throws {
  let empty = MobileCloudSession(
    credentials: .init(phone: "", token: "token"), transport: ScriptedHTTPTransport([]))
  await #expect(throws: MobileCloudError.invalidCredentials) { try await empty.connect() }
  let nonce = MobileCloudSession(
    credentials: .init(phone: "phone", token: "token"), transport: ScriptedHTTPTransport([]),
    now: { Date() }, nonce: { "short" })
  await #expect(throws: MobileCloudError.invalidResponse) { try await nonce.connect() }
  for value in ["http://example.invalid/file", "https://user:secret@example.invalid/file"] {
    await #expect(throws: MobileCloudError.invalidResponse) {
      _ = try await empty.unsignedDownload(URL(string: value)!, range: nil)
    }
  }
}

@Test func mobileRecoveryErrorKeepsBothCausesAndConfirmedPath() throws {
  let failure = MobileCloudMoveFailure(
    lastConfirmedPath: "/temporary", original: RemoteError.posix(ENOSPC),
    recovery: MobileCloudError.loginRequired)
  let error = failure as NSError
  #expect(error.domain == NSPOSIXErrorDomain)
  #expect(error.code == Int(EIO))
  #expect(error.localizedDescription.contains("/temporary"))
  #expect((error.userInfo[NSUnderlyingErrorKey] as? RemoteError) == .posix(ENOSPC))
  #expect(
    error.userInfo[NSLocalizedFailureReasonErrorKey] as? String
      == MobileCloudError.loginRequired.localizedDescription)
  #expect(failure.requiresLogin)
  for value in [
    MobileCloudError.invalidCredentials, .invalidResponse, .verificationRequired, .loginRequired,
  ] {
    #expect(!(value as NSError).localizedDescription.isEmpty)
  }
}

@Test func chinaBusinessErrorsAndMalformedFlexibleValuesRemainExplicit() throws {
  for (code, expected) in [(404, ENOENT), (409, EEXIST), (507, ENOSPC)] {
    #expect(ChinaWebSupport.mapBusiness(code: code, message: nil) == .posix(expected))
  }
  // 认不出的错误码要把对方原话和错误码写出来，不能只剩 EIO
  #expect(
    ChinaWebSupport.mapBusiness(code: 999, message: "busy", rawCode: "999")
      == .failed(EIO, LF("移动云盘返回错误：%@（错误码 %@）", "busy", "999")))
  #expect(ChinaWebSupport.mapBusiness(code: 200, message: "file size too large") == .posix(EFBIG))
  #expect(ChinaWebSupport.mapBusiness(code: 200, message: "same name") == .posix(EEXIST))
  #expect(ChinaWebSupport.mapBusiness(code: 429, message: nil) == .rateLimited)
  #expect(ChinaWebSupport.mapBusiness(code: 401, message: nil) == .unauthorized)
  #expect(try JSONDecoder().decode(FlexibleString.self, from: Data("123".utf8)).value == "123")
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(FlexibleString.self, from: Data("true".utf8))
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(FlexibleInt64.self, from: Data("1.5".utf8))
  }
  #expect(ChinaWebSupport.parseDate("2026-11-04T01:02:03.125Z").timeIntervalSince1970 > 0)
  #expect(ChinaWebSupport.parseDate("2026-11-04T01:02:03Z").timeIntervalSince1970 > 0)
  #expect(ChinaWebSupport.parseDate("2026-11-04 01:02:03").timeIntervalSince1970 > 0)
  #expect(ChinaWebSupport.parseDate("broken") == Date(timeIntervalSince1970: 0))
}

@Test func mobileSha1DigestMatchesKnownBytesAndRejectsUnknownAlgorithms() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("abc".utf8).write(to: file)
  #expect(
    try ChinaWebSupport.fileDigest(file, algorithm: "SHA1")
      == "a9993e364706816aba3e25717850c26c9cd0d89d")
  #expect(throws: RemoteError.unsupported) {
    try ChinaWebSupport.fileDigest(file, algorithm: "sha512")
  }
}
