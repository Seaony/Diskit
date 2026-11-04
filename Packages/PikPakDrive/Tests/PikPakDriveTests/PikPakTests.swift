import Core
import Foundation
import Synchronization
import Testing

@testable import PikPakDrive

private final class PikPakSecrets: SecretStore, Sendable {
  let nextRead = Mutex<AsyncStream<Void>.Continuation?>(nil)
  let failWrites = Mutex(false)
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? {
    let value = values.withLock { $0[key] }
    nextRead.withLock { observer in
      observer?.yield(())
      observer?.finish()
      observer = nil
    }
    return value
  }
  func write(_ data: Data, for key: String) throws {
    if failWrites.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    values.withLock { $0[key] = data }
  }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

private actor FakePikPakHTTP: HTTPTransport {
  let reply: @Sendable (URLRequest) async throws -> HTTPResponse
  let streamReply: @Sendable (URLRequest) async throws -> HTTPStreamResponse
  private(set) var requests: [URLRequest] = []

  init(
    reply: @escaping @Sendable (URLRequest) async throws -> HTTPResponse,
    streamReply: (@Sendable (URLRequest) async throws -> HTTPStreamResponse)? = nil
  ) {
    self.reply = reply
    self.streamReply =
      streamReply
      ?? { request in
        let response = try await reply(request)
        return HTTPStreamResponse(
          response: response,
          body: AsyncThrowingStream { continuation in
            if !response.body.isEmpty { continuation.yield(response.body) }
            continuation.finish()
          })
      }
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try await reply(request)
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.append(request)
    return try await streamReply(request)
  }
}

private func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
}

private func stub(_ request: URLRequest) throws -> HTTPResponse {
  let path = request.url?.path ?? ""
  if path == "/v1/shield/captcha/init" {
    return json(["captcha_token": "captcha", "expires_in": 300])
  }
  if path == "/v1/auth/token" {
    return json([
      "access_token": "fresh-access", "refresh_token": "fresh-refresh", "expires_in": 7200,
      "sub": "user",
    ])
  }
  if path == "/v1/user/me" {
    return json(["sub": "user", "name": "PikPak User", "email": "u@example.com"])
  }
  if path == "/drive/v1/about" {
    return json(["quota": ["limit": "1000", "usage": "400"]])
  }
  if path == "/v1/auth/signin" {
    return json([
      "access_token": "signed-access", "refresh_token": "signed-refresh", "expires_in": 7200,
      "sub": "user",
    ])
  }
  throw RemoteError.protocolError
}

private func authorization(
  access: String = "access", refresh: String = "refresh",
  expiresAt: TimeInterval = Date().timeIntervalSince1970 + 7200
) -> Data {
  try! JSONEncoder().encode(
    StoredPikPakAuthorization(
      accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
      deviceID: String(repeating: "a", count: 32),
      userID: "user"))
}

private func session(
  transport: FakePikPakHTTP, key: String = "pikpak.test"
) throws -> (PikPakSession, PikPakSecrets) {
  let secrets = PikPakSecrets()
  try secrets.write(authorization(), for: key)
  return (
    PikPakSession(
      secretKey: key, secrets: secrets, transport: transport),
    secrets
  )
}

private func pikPakFile(
  _ id: String, _ name: String, folder: Bool = false, size: Int64 = 4
) -> [String: Any] {
  [
    "id": id, "name": name, "kind": folder ? "drive#folder" : "drive#file",
    "size": String(size), "modified_time": "2026-01-01T00:00:00.000Z",
    "phase": "PHASE_TYPE_COMPLETE",
  ]
}

private func withFile<Result>(
  _ data: Data, _ operation: (URL) async throws -> Result
) async throws -> Result {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  return try await operation(url)
}

@Test func paginationReadsEveryPageWithPageTokens() async throws {
  let page = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files" {
      let values = try #require(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
      let token = values.first { $0.name == "page_token" }?.value ?? ""
      let current = page.withLock { value -> Int in
        defer { value += 1 }
        return value
      }
      if current == 0 {
        #expect(token == "")
        return json(["files": [pikPakFile("a", "a.txt")], "next_page_token": "next"])
      }
      #expect(token == "next")
      return json(["files": [pikPakFile("b", "b.txt")], "next_page_token": ""])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.map(\.name) == ["a.txt", "b.txt"])
  #expect(page.withLock { $0 } == 2)
}

@Test func authorizationRefreshesRejectedTokenAndRetries() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/token" {
      #expect(
        request.value(forHTTPHeaderField: "Content-Type")
          == "application/x-www-form-urlencoded")
      let form = try #require(
        URLComponents(
          url: URL(
            string: "https://example.invalid/?"
              + String(decoding: request.httpBody ?? Data(), as: UTF8.self))!,
          resolvingAgainstBaseURL: false)?.queryItems)
      #expect(form.contains { $0.name == "grant_type" && $0.value == "refresh_token" })
      #expect(form.contains { $0.name == "refresh_token" && $0.value == "refresh" })
    }
    if request.url?.path == "/drive/v1/about" {
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer access" {
        return HTTPResponse(
          status: 401, body: Data(#"{"error":"unauthenticated","error_code":16}"#.utf8))
      }
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
    }
    return try stub(request)
  }
  let (session, secrets) = try session(transport: transport)
  let response = try await session.authorized(
    URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!))
  #expect(response.status == 200)
  let requests = await transport.requests
  #expect(requests.filter { $0.url?.path == "/v1/auth/token" }.count == 1)
  #expect(requests.filter { $0.url?.path == "/drive/v1/about" }.count == 2)
  let saved = try #require(try secrets.read("pikpak.test"))
  let stored = try JSONDecoder().decode(StoredPikPakAuthorization.self, from: saved)
  #expect(stored.accessToken == "fresh-access")
  #expect(stored.refreshToken == "fresh-refresh")
}

@Test func loginRefreshesCaptchaOnceWhenServerRejectsIt() async throws {
  let captchaCount = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/shield/captcha/init" {
      let number = captchaCount.withLock { value -> Int in
        defer { value += 1 }
        return value
      }
      return json(["captcha_token": "captcha-\(number)", "expires_in": 300])
    }
    if request.url?.path == "/v1/auth/signin" {
      if request.value(forHTTPHeaderField: "x-captcha-token") == "captcha-0" {
        return json(
          ["error": "captcha_invalid", "error_code": 4002, "error_description": "stale"],
          status: 400)
      }
      #expect(request.value(forHTTPHeaderField: "x-captcha-token") == "captcha-1")
    }
    return try stub(request)
  }
  let session = PikPakSession(
    secretKey: "captcha-retry", secrets: PikPakSecrets(), transport: transport)
  _ = try await session.login(username: "person@example.com", password: "secret")
  let requests = await transport.requests
  #expect(requests.filter { $0.url?.path == "/v1/auth/signin" }.count == 2)
  let signinCaptchas = requests.filter { request in
    guard request.url?.path == "/v1/shield/captcha/init",
      let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        as? [String: Any]
    else { return false }
    return body["action"] as? String == "POST:/v1/auth/signin"
  }
  #expect(signinCaptchas.count == 2)
}

@Test func loginUsesAccountPasswordAndPersistsReturnedToken() async throws {
  let transport = FakePikPakHTTP { try stub($0) }
  let secrets = PikPakSecrets()
  let session = PikPakSession(
    secretKey: "login", secrets: secrets, transport: transport)
  let account = try await session.login(username: "person@example.com", password: "secret")
  #expect(account.nickname == "PikPak User")
  let requests = await transport.requests
  let signin = try #require(requests.first { $0.url?.path == "/v1/auth/signin" })
  let body = try #require(
    JSONSerialization.jsonObject(with: signin.httpBody ?? Data()) as? [String: String])
  #expect(body["username"] == "person@example.com" && body["password"] == "secret")
  let saved = try #require(try secrets.read("login"))
  #expect(!saved.isEmpty)
}

@Test func rangeUsesSignedDownloadURLWithoutAuthorization() async throws {
  let transport = FakePikPakHTTP(
    reply: { request in
      if request.url?.path == "/drive/v1/files" {
        return json([
          "files": [pikPakFile("video", "movie.mp4", size: 1024)], "next_page_token": "",
        ])
      }
      if request.url?.path == "/drive/v1/files/video" {
        var detailed = pikPakFile("video", "movie.mp4", size: 1024)
        detailed["links"] = [
          "application/octet-stream": [
            "url": "https://download.example/file?sig=test"
          ]
        ]
        return json(detailed)
      }
      return try stub(request)
    },
    streamReply: { request in
      #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return HTTPStreamResponse(
        response: HTTPResponse(
          status: 206, headers: ["Content-Range": "bytes 10-19/1024"],
          body: Data(repeating: 7, count: 10)),
        body: AsyncThrowingStream { continuation in
          continuation.yield(Data(repeating: 7, count: 10))
          continuation.finish()
        })
    })
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  var output = Data()
  for try await chunk in try await provider.read(
    RemotePath("/movie.mp4"), range: 10..<20)
  {
    output.append(chunk)
  }
  #expect(output == Data(repeating: 7, count: 10))
}

@Test func errorMappingCoversHTTPAndPikPakReasons() {
  #expect(PikPakHTTP.map(status: 404, body: nil) == .posix(ENOENT))
  #expect(PikPakHTTP.map(status: 401, body: nil) == .posix(EACCES))
  #expect(PikPakHTTP.map(status: 409, body: nil) == .posix(EEXIST))
  #expect(PikPakHTTP.map(status: 429, body: nil) == .rateLimited)
  #expect(PikPakHTTP.map(status: 507, body: nil) == .posix(ENOSPC))
  #expect(
    PikPakHTTP.map(
      status: 400, body: Data(#"{"error":"file_duplicated_name","error_code":3}"#.utf8))
      == .posix(EEXIST))
  #expect(
    PikPakHTTP.map(
      status: 400, body: Data(#"{"error":"file_space_not_enough","error_code":8}"#.utf8))
      == .posix(ENOSPC))
}

@Test func multipartBoundarySplitsZeroExactAndRemainder() throws {
  let partSize: Int64 = 100 * 1024
  #expect(try PikPakPart.split(size: 0, requestedPartSize: partSize).isEmpty)
  #expect(
    try PikPakPart.split(size: partSize, requestedPartSize: partSize)
      == [PikPakPart(number: 1, offset: 0, length: partSize)])
  #expect(
    try PikPakPart.split(size: partSize * 2, requestedPartSize: partSize).map(\.length)
      == [partSize, partSize])
  #expect(
    try PikPakPart.split(size: partSize * 2 + 7, requestedPartSize: partSize) == [
      PikPakPart(number: 1, offset: 0, length: partSize),
      PikPakPart(number: 2, offset: partSize, length: partSize),
      PikPakPart(number: 3, offset: partSize * 2, length: 7),
    ])
}

@Test func uploadWritesEveryPartAndCompletesInOrder() async throws {
  let partSize: Int64 = 100 * 1024
  let content = Data((0..<Int(partSize * 2 + 7)).map { UInt8(truncatingIfNeeded: $0) })
  let transport = FakePikPakHTTP { request in
    let host = request.url?.host
    if host == "mypikpak.com", request.httpMethod == "POST",
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        where: { $0.name == "uploads" }) == true
    {
      return HTTPResponse(
        status: 200,
        body: Data(
          "<CreateMultipartUploadResult><UploadId>upload-id</UploadId></CreateMultipartUploadResult>"
            .utf8))
    }
    if host == "mypikpak.com", request.httpMethod == "PUT" {
      let part = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "partNumber" }?.value
      return HTTPResponse(status: 200, headers: ["ETag": "\"etag-\(part ?? "")\""])
    }
    if host == "mypikpak.com", request.httpMethod == "POST" {
      return HTTPResponse(status: 200)
    }
    if request.url?.path == "/drive/v1/files", request.httpMethod == "GET" {
      return json(["files": [], "next_page_token": ""])
    }
    if request.url?.path == "/drive/v1/files", request.httpMethod == "POST" {
      var file = pikPakFile("new", "big.bin", size: Int64(content.count))
      file["phase"] = "PHASE_TYPE_RUNNING"
      return json([
        "file": file,
        "upload_type": "UPLOAD_TYPE_RESUMABLE",
        "resumable": [
          "params": [
            "access_key_id": "key", "access_key_secret": "secret", "bucket": "bucket",
            "key": "object", "security_token": "token",
          ]
        ],
      ])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session, partSize: partSize)
  try await provider.connect()
  try await withFile(content) {
    try await provider.write(RemotePath("/big.bin"), from: $0)
  }
  let requests = await transport.requests
  let puts = requests.filter { $0.url?.host == "mypikpak.com" && $0.httpMethod == "PUT" }
  #expect(puts.map { $0.httpBody?.count } == [Int(partSize), Int(partSize), 7])
  let complete = requests.last {
    $0.url?.host == "mypikpak.com" && $0.httpMethod == "POST"
      && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        where: { $0.name == "uploadId" }) == true
  }
  #expect(complete?.value(forHTTPHeaderField: "Content-Type") == "application/xml")
  #expect(String(data: complete?.httpBody ?? Data(), encoding: .utf8)?.contains("etag-1") == true)
}

@Test func existingNameFailsBeforeUploadTicket() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files", request.httpMethod == "GET" {
      return json(["files": [pikPakFile("old", "same.txt")], "next_page_token": ""])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  _ = try await withFile(Data("new".utf8)) { file in
    await #expect(throws: RemoteError.posix(EEXIST)) {
      try await provider.write(RemotePath("/same.txt"), from: file)
    }
  }
  let requests = await transport.requests
  #expect(
    !requests.contains {
      $0.url?.path == "/drive/v1/files" && $0.httpMethod == "POST"
    })
}

@Test func contentRangeMustMatchRequestedSliceAndSize() {
  #expect(
    PikPakProvider.validContentRange("bytes 10-19/1024", requested: 10..<20, size: 1024))
  #expect(
    !PikPakProvider.validContentRange("bytes 0-9/1024", requested: 10..<20, size: 1024))
  #expect(
    !PikPakProvider.validContentRange("bytes 10-19/1000", requested: 10..<20, size: 1024))
}

@Test(arguments: [0, 429, 500, 401])
func pikPakTransientRefreshFailurePreservesLogin(_ status: Int) async throws {
  let transport = FakePikPakHTTP { request in
    guard request.url?.path == "/v1/auth/token" else { throw RemoteError.protocolError }
    if status == 0 { throw URLError(.notConnectedToInternet) }
    return HTTPResponse(status: status, body: Data("{}".utf8))
  }
  let (session, secrets) = try session(transport: transport)
  let original = authorization(expiresAt: 0)
  try secrets.write(original, for: "pikpak.test")
  do {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!))
    Issue.record("刷新失败不应成功")
  } catch { #expect((error as? PikPakError) != .loginRequired) }
  #expect(try secrets.read("pikpak.test") == original)
  #expect(try await session.hasToken())
}

@Test func pikPakExplicitInvalidGrantRequiresNewLogin() async throws {
  let transport = FakePikPakHTTP { request in
    guard request.url?.path == "/v1/auth/token" else { throw RemoteError.protocolError }
    return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
  }
  let (session, secrets) = try session(transport: transport)
  try secrets.write(authorization(expiresAt: 0), for: "pikpak.test")
  await #expect(throws: PikPakError.loginRequired) {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!))
  }
  #expect(try await !session.hasToken())
}

@Test func pikPakRefreshRecoversAfterTemporaryFailureWithoutLogin() async throws {
  let attempts = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/token" {
      let number = attempts.withLock {
        $0 += 1
        return $0
      }
      if number == 1 { return HTTPResponse(status: 500) }
    }
    return try stub(request)
  }
  let (session, secrets) = try session(transport: transport)
  try secrets.write(authorization(expiresAt: 0), for: "pikpak.test")
  let request = URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!)
  await #expect(throws: RemoteError.http(500)) { _ = try await session.authorized(request) }
  #expect(try await session.authorized(request).status == 200)
  let stored = try JSONDecoder().decode(
    StoredPikPakAuthorization.self, from: #require(try secrets.read("pikpak.test")))
  #expect(stored.refreshToken == "fresh-refresh")
  #expect(attempts.withLock { $0 } == 2)
}

@Test func pikPakSecondResourceRejectionPreservesRefreshedLogin() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/about" { return HTTPResponse(status: 401) }
    return try stub(request)
  }
  let (session, secrets) = try session(transport: transport)
  await #expect(throws: PikPakError.loginRequired) {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!))
  }
  #expect(try await session.hasToken())
  let saved = try JSONDecoder().decode(
    StoredPikPakAuthorization.self, from: #require(try secrets.read("pikpak.test")))
  #expect(!saved.invalidated && saved.refreshToken == "fresh-refresh")
}

@Test(arguments: [false, true])
func pikPakRetriesPersistingRotatedTokenBeforeRefreshingAgain(newSession: Bool) async throws {
  let refreshes = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/token" {
      let count = refreshes.withLock {
        $0 += 1
        return $0
      }
      if count > 1 {
        return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
      }
    }
    return try stub(request)
  }
  let (session, secrets) = try session(transport: transport)
  try secrets.write(authorization(expiresAt: 0), for: "pikpak.test")
  let request = URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!)
  secrets.failWrites.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { _ = try await session.authorized(request) }
  secrets.failWrites.withLock { $0 = false }
  let retrySession =
    newSession
    ? PikPakSession(secretKey: "pikpak.test", secrets: secrets, transport: transport) : session
  #expect(try await retrySession.authorized(request).status == 200)
  let saved = try JSONDecoder().decode(
    StoredPikPakAuthorization.self, from: #require(try secrets.read("pikpak.test")))
  #expect(saved.refreshToken == "fresh-refresh")
  #expect(refreshes.withLock { $0 } == 1)
}

@Test(arguments: [false, true])
func pikPakSeparateSessionsShareRefresh(separateSessions: Bool) async throws {
  let secrets = PikPakSecrets()
  try secrets.write(authorization(expiresAt: 0), for: "concurrent")
  let started = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let count = Mutex(0)
  let http = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/token" {
      let number = count.withLock {
        $0 += 1
        return $0
      }
      if number == 1 {
        started.continuation.yield(())
        started.continuation.finish()
        for await _ in release.stream { break }
      }
    }
    return try stub(request)
  }
  let first = PikPakSession(secretKey: "concurrent", secrets: secrets, transport: http)
  let second =
    separateSessions
    ? PikPakSession(secretKey: "concurrent", secrets: secrets, transport: http) : first
  let firstTask = Task { try await first.account() }
  for await _ in started.stream { break }
  let read = AsyncStream<Void>.makeStream()
  secrets.nextRead.withLock { $0 = read.continuation }
  let secondTask = Task { try await second.account() }
  for await _ in read.stream { break }
  release.continuation.yield(())
  release.continuation.finish()
  _ = try await firstTask.value
  _ = try await secondTask.value
  #expect(count.withLock { $0 } == 1)
}
