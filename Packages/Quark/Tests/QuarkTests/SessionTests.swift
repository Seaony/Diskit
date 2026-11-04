import CoreTestSupport
import Core
import Foundation
import Synchronization
import Testing

@testable import Quark

private let goodQuarkCookie = "__puus=session; __pus=user; extra=value=="

private typealias SessionSecrets = TestSecretStore

private actor SessionHTTP: HTTPTransport {
  var requests: [URLRequest] = []
  var uploads: [URLRequest] = []
  let reply: @Sendable (URLRequest) async throws -> HTTPResponse
  init(_ reply: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
    self.reply = reply
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    uploads.append(request)
    return try await send(request)
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try await reply(request)
  }
}

private func quarkMetadata(headers: [String: String] = [:]) -> HTTPResponse {
  HTTPResponse(
    status: 200, headers: headers,
    body: Data(#"{"success":true,"data":{"nickname":"测试账户","uid":"returned-id"}}"#.utf8))
}
private func quarkSpace() -> HTTPResponse {
  HTTPResponse(
    status: 200,
    body: Data(
      #"{"status":200,"code":0,"data":{"total_capacity":9000000000,"use_capacity":1234567890}}"#
        .utf8))
}
private func quarkAPI(_ path: String = "/file/sort") -> URLRequest {
  URLRequest(url: URL(string: "https://drive.quark.cn/1/clouddrive" + path + "?pr=ucpro&fr=pc")!)
}

@Test func quarkLoginVerifiesIdentityAndQuotaBeforeSavingCookie() async throws {
  let key = "valid.cookie"
  let secrets = SessionSecrets()
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    #expect(try secrets.read(key) == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == QuarkSession.userAgent)
    #expect(request.value(forHTTPHeaderField: "Referer") == "https://pan.quark.cn/")
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=") == true)
    #expect(request.timeoutInterval == 30)
    return request.url?.path == "/account/info" ? quarkMetadata() : quarkSpace()
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  let account = try await session.login(cookie: goodQuarkCookie)
  #expect(account.nickname == "测试账户" && account.userID == "returned-id")
  #expect(account.total == 9_000_000_000 && account.used == 1_234_567_890)
  #expect(try await session.hasCookie())
  #expect(try secrets.string(key)?.contains("extra=value==") == true)
  #expect(
    await transport.requests.map { $0.url?.path } == ["/account/info", "/1/clouddrive/member"])
}

@Test func ucLoginUsesUCEndpointsAndCookies() async throws {
  let key = "uc.cookie"
  let secrets = SessionSecrets()
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    #expect(request.url?.host == "drive.uc.cn" || request.url?.host == "pc-api.uc.cn")
    #expect(request.value(forHTTPHeaderField: "Referer") == "https://drive.uc.cn/")
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=") == true)
    if request.url?.path == "/account/info" {
      return quarkMetadata(headers: [
        "Set-Cookie": "__puus=uc-session; Domain=.uc.cn; Path=/; Secure; HttpOnly"
      ])
    }
    return quarkSpace()
  }
  let session = QuarkSession(
    secretKey: key, secrets: secrets, configuration: .uc, transport: transport)
  let account = try await session.login(cookie: goodQuarkCookie)
  #expect(account.nickname == "测试账户")
  #expect(try secrets.string(key)?.contains("__puus=uc-session") == true)
  let urls = await transport.requests.compactMap(\.url)
  #expect(urls[0].absoluteString.hasPrefix("https://drive.uc.cn/account/info"))
  #expect(urls[1].absoluteString.hasPrefix("https://pc-api.uc.cn/1/clouddrive/member?"))
}

@Test func quarkMissingUserIDIsNotFabricatedFromCookieOrNickname() async throws {
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    if request.url?.path == "/account/info" {
      return HTTPResponse(
        status: 200, body: Data(#"{"success":true,"data":{"nickname":"无ID账户"}}"#.utf8))
    }
    return quarkSpace()
  }
  let session = QuarkSession(
    secretKey: "no-id.cookie", secrets: SessionSecrets(), transport: transport)
  let result = try await session.login(cookie: goodQuarkCookie)
  #expect(result.userID.isEmpty)
  #expect(result.nickname == "无ID账户")
}

@Test func quarkRejectsMissingOrMalformedCookieBeforeNetwork() async throws {
  let secrets = SessionSecrets()
  let transport = SessionHTTP { _ in throw URLError(.badServerResponse) }
  let session = QuarkSession(secretKey: "invalid.cookie", secrets: secrets, transport: transport)
  for value in [
    "", "__puus=x", "__pus=x", "__puus=; __pus=x", "__puus=x\r\nX-Header: injected; __pus=y",
    "Cookie: __puus=x; __pus=y",
  ] {
    await #expect(throws: QuarkError.invalidCookie) { try await session.login(cookie: value) }
  }
  #expect(await transport.requests.isEmpty)
  #expect(try await !session.hasCookie())
}

@Test func quarkInvalidCandidateDoesNotReplaceValidSavedCookieOrNotify() async throws {
  let key = UUID().uuidString + ".cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let events = Mutex(0)
  let observer = NotificationCenter.default.addObserver(
    forName: QuarkSession.loginInvalidatedNotification, object: nil, queue: nil
  ) { note in
    if note.userInfo?["secretKey"] as? String == key { events.withLock { $0 += 1 } }
  }
  defer { NotificationCenter.default.removeObserver(observer) }
  let transport = SessionHTTP { _ in
    HTTPResponse(status: 401, body: Data(#"{"status":401,"code":31001}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  await #expect(throws: QuarkError.loginRequired) {
    try await session.login(cookie: "__puus=wrong; __pus=wrong")
  }
  #expect(try secrets.string(key) == goodQuarkCookie)
  #expect(events.withLock { $0 } == 0)
}

@Test func quarkCandidateRefreshIsKeptLocalUntilCapacityValidationSucceeds() async throws {
  let key = "candidate.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    #expect(try secrets.string(key) == goodQuarkCookie)
    if request.url?.path == "/account/info" {
      return quarkMetadata(headers: [
        "Set-Cookie": "__puus=new-session; Domain=.quark.cn; Path=/; Secure; HttpOnly"
      ])
    }
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=new-session") == true)
    return HTTPResponse(status: 500)
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  await #expect(throws: QuarkError.invalidResponse) {
    try await session.login(cookie: "__puus=candidate; __pus=candidate")
  }
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkMissingCookieReturnsEACCESAndOneRedactedNotification() async throws {
  let key = UUID().uuidString + ".cookie"
  let events = Mutex(0)
  let observer = NotificationCenter.default.addObserver(
    forName: QuarkSession.loginInvalidatedNotification, object: nil, queue: nil
  ) { note in
    if note.userInfo?["secretKey"] as? String == key {
      #expect(note.userInfo?.count == 1)
      events.withLock { $0 += 1 }
    }
  }
  defer { NotificationCenter.default.removeObserver(observer) }
  let transport = SessionHTTP { _ in throw URLError(.badServerResponse) }
  let session = QuarkSession(secretKey: key, secrets: SessionSecrets(), transport: transport)
  for _ in 0..<2 {
    await #expect(throws: QuarkError.loginRequired) { try await session.authorized(quarkAPI()) }
  }
  #expect(events.withLock { $0 } == 1)
  #expect(await transport.requests.isEmpty)
  let error = QuarkError.loginRequired as NSError
  #expect(error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES))
}

@Test func quarkHTTPAndBusinessUnauthorizedResponsesPreserveCookieForRecovery() async throws {
  let responses = [
    HTTPResponse(status: 401),
    HTTPResponse(status: 200, body: Data(#"{"status":401,"code":31001,"message":"未登录"}"#.utf8)),
  ]
  for response in responses {
    let key = UUID().uuidString + ".cookie"
    let secrets = SessionSecrets()
    try secrets.write(Data(goodQuarkCookie.utf8), for: key)
    let session = QuarkSession(
      secretKey: key, secrets: secrets, transport: SessionHTTP { _ in response })
    await #expect(throws: QuarkError.loginRequired) { try await session.authorized(quarkAPI()) }
    #expect(try secrets.string(key) == goodQuarkCookie)
    #expect(try await session.hasCookie())
  }
}

@Test func quarkSetCookieRefreshPreservesOtherValuesAndWritesBack() async throws {
  let key = "refresh.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { _ in
    HTTPResponse(
      status: 200,
      headers: ["set-cookie": "__puus=next==; Domain=.quark.cn; Path=/; Secure; HttpOnly"],
      body: Data(#"{"status":200,"code":0,"data":{}}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  _ = try await session.authorized(quarkAPI())
  let updated = try #require(try secrets.string(key))
  #expect(updated.contains("__puus=next=="))
  #expect(updated.contains("__pus=user"))
  #expect(updated.contains("extra=value=="))
  #expect(!updated.contains("Domain=") && !updated.contains("HttpOnly"))
}

@Test func quarkDeletedAuthCookieRequiresLogin() async throws {
  let key = "expired.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { _ in
    HTTPResponse(
      status: 200, headers: ["Set-Cookie": "__puus=; Domain=.quark.cn; Path=/; Max-Age=0"],
      body: Data(#"{"status":200,"code":0}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  await #expect(throws: QuarkError.loginRequired) { try await session.authorized(quarkAPI()) }
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkCookieNeverLeaksToOSSOrLookalikeHostsAndSignatureHeadersSurvive() async throws {
  let key = "scope.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "OSS signed-authorization")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "upload-agent")
    #expect(request.value(forHTTPHeaderField: "Referer") == "https://pan.quark.cn/")
    #expect(request.value(forHTTPHeaderField: "x-oss-date") == "date")
    return HTTPResponse(
      status: 403, headers: ["Set-Cookie": "__puus=attacker; Domain=.quark.cn; Path=/"],
      body: Data(#"{"code":31001}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  for host in ["bucket.oss-cn-hangzhou.aliyuncs.com", "quark.cn.example.com", "fakequark.cn"] {
    var request = URLRequest(url: URL(string: "https://" + host + "/object")!)
    request.httpMethod = "PUT"
    request.setValue(goodQuarkCookie, forHTTPHeaderField: "Cookie")
    request.setValue("OSS signed-authorization", forHTTPHeaderField: "Authorization")
    request.setValue("upload-agent", forHTTPHeaderField: "User-Agent")
    request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
    request.setValue("date", forHTTPHeaderField: "x-oss-date")
    #expect(try await session.authorized(request).status == 403)
  }
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkTrustedDownloadKeepsCookieAndUsesSameBrowserUA() async throws {
  let key = "download.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let bytes = Data(repeating: 0x5a, count: 2_000_000)
  let transport = SessionHTTP { (request: URLRequest) async throws -> HTTPResponse in
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=session") == true)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == QuarkSession.userAgent)
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=12-2000011")
    return HTTPResponse(
      status: 206, headers: ["Content-Type": "application/octet-stream"], body: bytes)
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  var request = URLRequest(url: URL(string: "https://download.quark.cn/original?sign=test")!)
  request.setValue("bytes=12-2000011", forHTTPHeaderField: "Range")
  let stream = try await session.authorizedStream(request)
  var result = Data()
  for try await data in stream.body { result.append(data) }
  #expect(result == bytes)
}

@Test func quarkStreamDetectsUnauthorizedBusinessEnvelope() async throws {
  let key = "stream-expired.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { _ in
    HTTPResponse(status: 200, body: Data(#"{"status":401,"code":31001}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  await #expect(throws: QuarkError.loginRequired) {
    _ = try await session.authorizedStream(quarkAPI())
  }
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkNonLoginBusinessErrorKeepsSavedCookie() async throws {
  let key = "other-error.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { _ in
    HTTPResponse(status: 403, body: Data(#"{"status":403,"code":33000}"#.utf8))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  #expect(try await session.authorized(quarkAPI()).status == 403)
  #expect(try await session.hasCookie())
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkServerFailureIsNotMistakenForExpiredLogin() async throws {
  let key = "server-error.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let session = QuarkSession(
    secretKey: key, secrets: secrets,
    transport: SessionHTTP { _ in
      HTTPResponse(status: 500, body: Data(#"{"success":false,"code":500}"#.utf8))
    })
  let request = URLRequest(url: URL(string: "https://pan.quark.cn/account/info")!)
  #expect(try await session.authorized(request).status == 500)
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkMultipleSetCookiesMergeWithoutTreatingExpiresCommaAsSeparator() async throws {
  let key = "multiple-refresh.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let session = QuarkSession(
    secretKey: key, secrets: secrets,
    transport: SessionHTTP { _ in
      HTTPResponse(
        status: 200,
        headers: [
          "Set-Cookie":
            "__puus=next-session; Domain=.quark.cn; Path=/; Expires=Fri, 01 Jan 2038 00:00:00 GMT, __pus=next-user; Domain=.quark.cn; Path=/; Max-Age=600"
        ], body: Data(#"{"status":200,"code":0}"#.utf8))
    })
  _ = try await session.authorized(quarkAPI())
  let cookie = try #require(try secrets.string(key))
  #expect(cookie.contains("__puus=next-session"))
  #expect(cookie.contains("__pus=next-user"))
  #expect(cookie.contains("extra=value=="))
}

@Test func quarkExternalRedirectCannotRefreshCookieForBufferedOrStreamedDownload() async throws {
  let key = "redirect.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let bytes = Data([1, 2, 3])
  let transport = SessionHTTP { _ in
    HTTPResponse(
      status: 200, headers: ["Set-Cookie": "__puus=foreign; Domain=.quark.cn; Path=/"],
      body: bytes, url: URL(string: "https://cdn.example.com/object"))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  let request = URLRequest(url: URL(string: "https://download.quark.cn/object")!)
  #expect(try await session.authorized(request).body == bytes)
  let stream = try await session.authorizedStream(request)
  var output = Data()
  for try await chunk in stream.body { output.append(chunk) }
  #expect(output == bytes)
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkLoginCannotBeValidatedByRedirectedForeignAccountResponse() async throws {
  let key = "redirect-login.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let transport = SessionHTTP { _ in
    HTTPResponse(
      status: 200, body: quarkMetadata().body,
      url: URL(string: "https://foreign.example.com/account/info"))
  }
  let session = QuarkSession(secretKey: key, secrets: secrets, transport: transport)
  await #expect(throws: QuarkError.invalidResponse) {
    try await session.login(cookie: "__puus=new; __pus=new")
  }
  #expect(try secrets.string(key) == goodQuarkCookie)
}

@Test func quarkExpiredDownloadSignatureDoesNotInvalidateLoginCookie() async throws {
  let key = "expired-link.cookie"
  let secrets = SessionSecrets()
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let session = QuarkSession(
    secretKey: key, secrets: secrets,
    transport: SessionHTTP { _ in
      HTTPResponse(status: 401, body: Data("expired download signature".utf8))
    })
  let request = URLRequest(
    url: URL(string: "https://download.quark.cn/original?signature=expired")!)
  #expect(try await session.authorized(request).status == 401)
  let stream = try await session.authorizedStream(request)
  #expect(stream.response.status == 401)
  #expect(try secrets.string(key) == goodQuarkCookie)
  #expect(try await session.hasCookie())
}

@Test func quarkTransferRoutingDoesNotChangeMetadataOrLeakCookie() async throws {
  let secrets = MemorySecretStore()
  try secrets.write(Data(goodQuarkCookie.utf8), for: "local")
  let http = SessionHTTP { request in
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    return HTTPResponse(status: 200)
  }
  let session = QuarkSession(secretKey: "local", secrets: secrets, transport: http)
  var request = URLRequest(url: URL(string: "https://upload.example.invalid/file")!)
  request.httpMethod = "PUT"
  request.httpBody = Data([1])
  _ = try await session.authorized(request, upload: true)
  _ = try await session.authorized(request)
  #expect(await http.requests.count == 2)
  #expect(await http.uploads.count == 1)
}

@Test func quarkTemporaryRejectionKeepsCookieAndCanRecover() async throws {
  let secrets = SessionSecrets()
  let key = UUID().uuidString
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let attempts = Mutex(0)
  let session = QuarkSession(
    secretKey: key, secrets: secrets,
    transport: SessionHTTP { _ in
      let attempt = attempts.withLock {
        $0 += 1
        return $0
      }
      return HTTPResponse(
        status: attempt == 1 ? 401 : 200, body: Data(#"{"status":200,"code":0}"#.utf8))
    })
  await #expect(throws: QuarkError.loginRequired) { _ = try await session.authorized(quarkAPI()) }
  #expect(try secrets.string(key) == goodQuarkCookie)
  #expect(try await session.authorized(quarkAPI()).status == 200)
  #expect(QuarkError.loginRequired.requiresLogin)
  #expect(!QuarkError.invalidCookie.requiresLogin)
  #expect(!QuarkError.invalidResponse.requiresLogin)
}

@Test func quarkServerFailureCannotDeleteCookieThroughLoginLikeBody() async throws {
  let secrets = SessionSecrets()
  let key = UUID().uuidString
  try secrets.write(Data(goodQuarkCookie.utf8), for: key)
  let session = QuarkSession(
    secretKey: key, secrets: secrets,
    transport: SessionHTTP { _ in
      HTTPResponse(
        status: 500, headers: ["Set-Cookie": "__puus=; Domain=.quark.cn; Path=/; Max-Age=0"],
        body: Data(#"{"status":401,"code":31001}"#.utf8))
    })
  #expect(try await session.authorized(quarkAPI()).status == 500)
  #expect(try secrets.string(key) == goodQuarkCookie)
}
