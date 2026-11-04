@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import PikPakDrive

private typealias PikPakSecrets = TestSecretStore

private actor FakePikPakHTTP: HTTPTransport {
  let reply: @Sendable (URLRequest) async throws -> HTTPResponse
  let streamReply: @Sendable (URLRequest) async throws -> HTTPStreamResponse
  private(set) var requests: [URLRequest] = []
  private(set) var uploads: [URLRequest] = []

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

  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    uploads.append(request)
    return try await send(request)
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

private let pikPakNow = Date(timeIntervalSince1970: 1_700_000_000)

private func authorization(
  access: String = "access", refresh: String = "refresh",
  expiresAt: TimeInterval = pikPakNow.timeIntervalSince1970 + 7200
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
      secretKey: key, secrets: secrets, transport: transport, now: { pikPakNow }),
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
    secretKey: "captcha-retry", secrets: PikPakSecrets(), transport: transport, now: { pikPakNow })
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
    secretKey: "login", secrets: secrets, transport: transport, now: { pikPakNow })
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
    if host == "mypikpak.com" {
      #expect(
        request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
    }
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
  #expect(await transport.uploads.count == 3)
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
    ? PikPakSession(secretKey: "pikpak.test", secrets: secrets, transport: transport, now: { pikPakNow }) : session
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
  let first = PikPakSession(secretKey: "concurrent", secrets: secrets, transport: http, now: { pikPakNow })
  let second =
    separateSessions
    ? PikPakSession(secretKey: "concurrent", secrets: secrets, transport: http, now: { pikPakNow }) : first
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

@Test func emptyPikPakObjectIsActuallyUploaded() async throws {
  let transport = FakePikPakHTTP { request in
    #expect(request.url?.host == "mypikpak.com")
    #expect(request.url?.path == "/bucket/empty")
    #expect(request.httpMethod == "PUT")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
    #expect(request.httpBody == nil || request.httpBody?.isEmpty == true)
    return HTTPResponse(status: 200)
  }
  let session = PikPakSession(secretKey: "test", secrets: MemorySecretStore(), transport: transport, now: { pikPakNow })
  let uploader = PikPakS3Uploader(session: session, partSize: 100 * 1024)
  let parameters = PikPakResumable.Parameters(
    accessKeyID: "local", accessKeySecret: "local", bucket: "bucket", key: "empty",
    securityToken: "local")
  try await withFile(Data()) { file in
    try await uploader.upload(from: file, size: 0, parameters: parameters, progress: nil)
  }
  #expect(await transport.requests.count == 1)
  #expect(await transport.uploads.count == 1)
}

@Test func customPikPakRootRemainsParentForListingAndCreation() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files" {
      if request.httpMethod == "GET" {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "parent_id" }?.value == "custom-root")
        return json(["files": [], "next_page_token": ""])
      }
      let body = try #require(
        JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      #expect(body["parent_id"] as? String == "custom-root")
      return json(["file": pikPakFile("created", "new", folder: true)])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session, rootFolderID: "custom-root")
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).isEmpty)
  try await provider.makeDirectory(RemotePath("/new"))
}

@Test func persistentCaptchaFailureDoesNotBlamePasswordOrInvalidateLogin() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/signin" {
      return json(["error": "captcha_invalid", "error_code": 4002], status: 400)
    }
    return try stub(request)
  }
  let (session, secrets) = try session(transport: transport)
  let before = try secrets.read("pikpak.test")
  await #expect(throws: PikPakError.captchaRequired) {
    _ = try await session.login(username: "local@example.invalid", password: "test")
  }
  #expect(try secrets.read("pikpak.test") == before)
  #expect(!PikPakError.captchaRequired.requiresLogin)
  #expect(PikPakError.loginRequired.requiresLogin)
}

@Test func captchaCacheIsBoundedAndChangesWithStoredIdentity() async throws {
  let count = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/shield/captcha/init" {
      let issued = count.withLock { $0 += 1; return $0 }
      // 到期时间各不相同，明确验证最早到期条目被淘汰。
      return json(["captcha_token": "captcha", "expires_in": 300 + issued])
    }
    return HTTPResponse(status: 200)
  }
  let (session, secrets) = try session(transport: transport)
  for id in 0..<65 {
    _ = try await session.authorized(
      URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/files/\(id)")!))
  }
  #expect(count.withLock { $0 } == 65)
  let last = URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/files/64")!)
  _ = try await session.authorized(last)
  #expect(count.withLock { $0 } == 65)
  _ = try await session.authorized(
    URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/files/0")!))
  #expect(count.withLock { $0 } == 66)
  var changed = try JSONDecoder().decode(
    StoredPikPakAuthorization.self, from: #require(try secrets.read("pikpak.test")))
  changed.userID = "other-user"
  changed.deviceID = "other-device"
  try secrets.write(JSONEncoder().encode(changed), for: "pikpak.test")
  _ = try await session.authorized(last)
  #expect(count.withLock { $0 } == 67)
}

@Test(arguments: [false, true])
func pikPakLateDirectoryResponseCannotRepopulateInvalidatedCache(disconnect: Bool) async throws {
  let started = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let calls = Mutex(0)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files" {
      let number = calls.withLock {
        $0 += 1
        return $0
      }
      if number == 1 {
        started.continuation.yield(())
        started.continuation.finish()
        for await _ in release.stream { break }
        return json(["files": [pikPakFile("old", "same")], "next_page_token": ""])
      }
      return json(["files": [pikPakFile("new", "same")], "next_page_token": ""])
    }
    if request.url?.path == "/drive/v1/files:batchTrash" {
      let body = try #require(
        JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      #expect(body["ids"] as? [String] == ["new"])
      return json([:])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  let late = Task { try await provider.list(RemotePath("/")) }
  for await _ in started.stream { break }
  if disconnect {
    await provider.disconnect()
  } else {
    _ = try await provider.list(RemotePath("/"))
  }
  release.continuation.yield(())
  release.continuation.finish()
  await #expect(throws: disconnect ? RemoteError.notConnected : .posix(EAGAIN)) {
    _ = try await late.value
  }
  if !disconnect { try await provider.remove(RemotePath("/same"), recursive: false) }
}

@Test func pikPakMoveRenamesByIdentityAfterDestinationAutoRename() async throws {
  let mutations = Mutex<[String]>([])
  let currentName = Mutex("old")
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files", request.httpMethod == "GET" {
      let parent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "parent_id" }?.value
      let entries: [[String: Any]]
      switch parent {
      case "source": entries = [pikPakFile("moving", "old")]
      case "target": entries = [pikPakFile("existing", "old")]
      default:
        entries = [
          pikPakFile("source", "src", folder: true), pikPakFile("target", "dst", folder: true),
        ]
      }
      return json(["files": entries, "next_page_token": ""])
    }
    if request.url?.path == "/drive/v1/files:batchMove" {
      mutations.withLock { $0.append("move") }
      currentName.withLock { $0 = "old(1)" }
      let body = try #require(
        JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      #expect(body["ids"] as? [String] == ["moving"])
      #expect((body["to"] as? [String: String])?["parent_id"] == "target")
      return json([:])
    }
    if request.url?.path == "/drive/v1/files/moving", request.httpMethod == "PATCH" {
      mutations.withLock { $0.append("rename") }
      let body = try #require(
        JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
      #expect(body["name"] == "new")
      #expect(currentName.withLock { $0 } == "old(1)")
      currentName.withLock { $0 = "new" }
      return json(pikPakFile("moving", "new"))
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  try await provider.move(RemotePath("/src/old"), to: RemotePath("/dst/new"))
  #expect(mutations.withLock { $0 } == ["move", "rename"])
  #expect(currentName.withLock { $0 } == "new")
}

@Test func pikPakMkdirRejectsExistingDirectory() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files", request.httpMethod == "GET" {
      return json(["files": [pikPakFile("existing", "dir", folder: true)], "next_page_token": ""])
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/dir"))
  }
  #expect(
    await transport.requests.filter { $0.url?.path == "/drive/v1/files" && $0.httpMethod == "POST" }
      .isEmpty)
}

@Test(arguments: [false, true])
func pikPakRangeReusesExpiringLinksAndRefreshesRejectedURL(reject: Bool) async throws {
  let details = Mutex(0)
  let downloads = Mutex(0)
  let expiry = String(Int64(pikPakNow.timeIntervalSince1970 + 600))
  let transport = FakePikPakHTTP(
    reply: { request in
      if request.url?.path == "/drive/v1/files" {
        return json(["files": [pikPakFile("video", "movie", size: 10)], "next_page_token": ""])
      }
      if request.url?.path == "/drive/v1/files/video" {
        let version = details.withLock {
          $0 += 1
          return $0
        }
        var file = pikPakFile("video", "movie", size: 10)
        file["links"] = [
          "application/octet-stream": [
            "url": "https://download.example.invalid/v\(version)?expire=\(expiry)"
          ]
        ]
        return json(file)
      }
      return try stub(request)
    },
    streamReply: { request in
      let number = downloads.withLock {
        $0 += 1
        return $0
      }
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      if reject, number == 2 {
        return HTTPStreamResponse(
          response: HTTPResponse(status: 403), body: AsyncThrowingStream { $0.finish() })
      }
      return HTTPStreamResponse(
        response: HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-1/10"]),
        body: AsyncThrowingStream {
          $0.yield(Data([1, 2]))
          $0.finish()
        })
    })
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session, now: { pikPakNow })
  try await provider.connect()
  for _ in 0..<2 {
    var data = Data()
    for try await chunk in try await provider.read(RemotePath("/movie"), range: 0..<2) {
      data.append(chunk)
    }
    #expect(data == Data([1, 2]))
  }
  #expect(details.withLock { $0 } == (reject ? 2 : 1))
  #expect(downloads.withLock { $0 } == (reject ? 3 : 2))
}

@Test(arguments: ["advancing", "stalled", "missing", "regressing", "slow"])
func pikPakTaskDeadlineTracksOnlyIncreasingProgress(mode: String) async throws {
  let clock = ManualTestClock()
  let waiting = TestEvent()
  let blocked = TestEvent()
  let calls = Mutex(0)
  let cancelled = Mutex(false)
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/tasks/local" {
      let count = calls.withLock {
        $0 += 1
        return $0
      }
      do {
        if mode == "slow" || (mode != "advancing" && count == 3) {
          waiting.signal()
          try await blocked.wait()
        }
        clock.advance(by: .seconds(1))
      } catch {
        cancelled.withLock { $0 = true }
        throw error
      }
      if (mode == "advancing" && count == 6) || count == 20 {
        return json(["id": "local", "phase": "PHASE_TYPE_COMPLETE", "progress": 100])
      }
      var task: [String: Any] = ["id": "local", "phase": "PHASE_TYPE_RUNNING"]
      switch mode {
      case "advancing": task["progress"] = count
      case "regressing": task["progress"] = count.isMultiple(of: 2) ? 1 : 2
      case "stalled": task["progress"] = 0
      default: break
      }
      return json(task)
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  let deadline = HTTPProgressDeadline(
    interval: .seconds(3),
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
  if mode == "advancing" {
    try await provider.waitTask("local", deadline: deadline, pollInterval: .zero)
    #expect(calls.withLock { $0 } == 6)
  } else {
    let operation = Task {
      try await provider.waitTask("local", deadline: deadline, pollInterval: .zero)
    }
    try await waiting.wait()
    await clock.waitForSleepRequests(1)
    clock.advance(by: mode == "slow" ? .seconds(4) : .milliseconds(2500))
    await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await operation.value }
    #expect(calls.withLock { $0 } < 20)
    if mode == "slow" { #expect(cancelled.withLock { $0 }) }
  }
}

@Test(arguments: [false, true])
func pikPakCancelledOrExpiredWaiterLeavesSharedRefreshRunning(cancel: Bool) async throws {
  let secrets = PikPakSecrets()
  try secrets.write(authorization(expiresAt: 0), for: "cancel-shared")
  let entered = TestEvent()
  let release = TestEvent()
  let clock = ManualTestClock()
  let count = Mutex(0)
  defer { release.signal() }
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/v1/auth/token" {
      count.withLock { $0 += 1 }
      entered.signal()
      try await release.wait()
      #expect(!Task.isCancelled)
    }
    return try stub(request)
  }
  let session = PikPakSession(secretKey: "cancel-shared", secrets: secrets, transport: transport, now: { pikPakNow }, makeDeadline: {
    HTTPProgressDeadline(interval: .seconds(30), clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0, tolerance: nil) }))
  })
  let request = URLRequest(url: URL(string: "https://api-drive.mypikpak.com/drive/v1/about")!)
  let caller = Task { try await session.authorized(request) }
  try await entered.wait()
  if cancel { caller.cancel() } else { await clock.waitForSleepRequests(1); clock.advance(by: .seconds(30)) }
  do { _ = try await caller.value; Issue.record("等待者应及时退出") }
  catch {
    if cancel { #expect(error is CancellationError) }
    else { #expect((error as? URLError)?.code == .timedOut) }
  }
  #expect(!release.isSignaled)
  let survivor = Task { try await session.authorized(request) }
  release.signal()
  #expect(try await survivor.value.status == 200)
  #expect(count.withLock { $0 } == 1)
}

@Test(arguments: [false, true])
func failedUploadKeepsPrimaryErrorWhenCleanupFails(asynchronous: Bool) async throws {
  let transport = FakePikPakHTTP { request in
    switch (request.httpMethod, request.url?.path) {
    case ("GET", "/drive/v1/files"):
      return json(["files": [], "next_page_token": ""])
    case ("POST", "/drive/v1/files"):
      var file = pikPakFile("unfinished", "failed.bin")
      file["phase"] = "PHASE_TYPE_RUNNING"
      return json(["file": file, "task": ["id": "upload-task", "phase": "PHASE_TYPE_RUNNING"]])
    case ("POST", "/drive/v1/files:batchDelete"):
      if asynchronous { return json(["task_id": "delete-task"]) }
      return HTTPResponse(status: 200, body: Data("invalid JSON".utf8))
    case ("GET", "/drive/v1/tasks/delete-task"):
      return json(["id": "delete-task", "phase": "PHASE_TYPE_ERROR"])
    case ("DELETE", "/drive/v1/tasks"):
      return HTTPResponse(status: 500)
    default: return try stub(request)
    }
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  _ = try await withFile(Data([1, 2, 3, 4])) { file in
    await #expect(throws: PikPakError.invalidResponse) {
      try await provider.write(RemotePath("/failed.bin"), from: file)
    }
  }
  let requests = await transport.requests
  #expect(requests.contains { $0.url?.path == "/drive/v1/files:batchDelete" })
  #expect(requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/drive/v1/tasks" })
  #expect(requests.contains { $0.url?.path == "/drive/v1/tasks/delete-task" } == asynchronous)
}

@Test func cancelledUploadCleanupRunsUncancelledAndKeepsCallerCancellation() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.path == "/drive/v1/files:batchDelete" {
      #expect(!Task.isCancelled)
      return HTTPResponse(status: 500)
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let provider = PikPakProvider(session: session)
  try await provider.connect()
  let file = try JSONDecoder().decode(PikPakFile.self, from: json(pikPakFile("unfinished", "failed.bin")).body)
  let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await provider.cleanupUpload(file, taskID: nil)
    try Task.checkCancellation()
  }
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  #expect(await transport.requests.contains { $0.url?.path == "/drive/v1/files:batchDelete" })
}

@Test func multipartCleanupHTTPFailureKeepsOriginalUploadFailure() async throws {
  let transport = FakePikPakHTTP { request in
    if request.url?.host == "mypikpak.com" {
      switch request.httpMethod {
      case "POST":
        return HTTPResponse(status: 200, body: Data(
          "<CreateMultipartUploadResult><UploadId>cleanup-test</UploadId></CreateMultipartUploadResult>".utf8))
      case "PUT": throw RemoteError.rateLimited
      case "DELETE":
        #expect(!Task.isCancelled)
        return HTTPResponse(status: 500)
      default: throw PikPakError.invalidResponse
      }
    }
    return try stub(request)
  }
  let (session, _) = try session(transport: transport)
  let parameters = try JSONDecoder().decode(PikPakResumable.Parameters.self, from: json([
    "access_key_id": "key", "access_key_secret": "secret", "bucket": "bucket",
    "key": "object", "security_token": "token",
  ]).body)
  let uploader = PikPakS3Uploader(session: session, partSize: 100 * 1024)
  _ = try await withFile(Data([1])) { file in
    await #expect(throws: RemoteError.rateLimited) {
      try await uploader.upload(from: file, size: 1, parameters: parameters, progress: nil)
    }
  }
  #expect(await transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.host == "mypikpak.com" })
}
