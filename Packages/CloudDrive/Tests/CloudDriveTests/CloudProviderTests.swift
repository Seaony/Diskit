import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private typealias MemorySecrets = TestSecretStore

private typealias FakeTransport = ScriptedHTTPTransport

private let oauthConfiguration = OAuthConfiguration(
  clientID: "client",
  clientSecret: "secret",
  authorizationURL: URL(string: "https://example.com/authorize")!,
  tokenURL: URL(string: "https://example.com/token")!,
  redirectURI: "diskit://oauth/test",
  scopes: [])

private func session(_ transport: FakeTransport) throws -> OAuthSession {
  let secrets = MemorySecrets()
  let token = OAuthToken(
    accessToken: "access", refreshToken: "refresh",
    expiresAt: .distantFuture)
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  return OAuthSession(
    configuration: oauthConfiguration, secretKey: "oauth", secrets: secrets, transport: transport)
}

@Test func oneDriveFollowsNextLink() async throws {
  let first = """
    {"value":[{"id":"file","name":"A.txt","size":3,"lastModifiedDateTime":"2026-01-01T00:00:00Z"}],
     "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children?page=2"}
    """
  let second = """
    {"value":[{"id":"folder","name":"Photos","folder":{}}]}
    """
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"quota":{"total":100,"used":10}}"#.utf8)),
    HTTPResponse(status: 200, body: Data(first.utf8)),
    HTTPResponse(status: 200, body: Data(second.utf8)),
  ])
  let provider = OneDriveProvider(session: try session(transport), transport: transport)
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["A.txt", "Photos"])
  #expect(items[1].isDirectory)
  #expect(transport.requests.withLock { $0.count } == 3)
}

@Test func oneDriveRangeReadAndErrorsAreMapped() async throws {
  let transport = FakeTransport(
    [HTTPResponse(status: 200)], streamResponse: HTTPResponse(status: 206))
  let oauth = try session(transport)
  #expect(try await oauth.hasToken())
  let provider = OneDriveProvider(session: oauth, transport: transport)
  try await provider.connect()
  let stream = try await provider.read(try RemotePath("/A.txt"), range: 10..<20)
  var result = Data()
  for try await chunk in stream { result.append(chunk) }
  #expect(result == Data("range".utf8))
  let request = try #require(transport.requests.withLock { $0.last })
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")

  let deniedTransport = FakeTransport([HTTPResponse(status: 200), HTTPResponse(status: 403)])
  let denied = OneDriveProvider(session: try session(deniedTransport), transport: deniedTransport)
  try await denied.connect()
  await #expect(throws: RemoteError.posix(EACCES)) {
    _ = try await denied.spaceInfo()
  }
}

@Test func googleDriveFollowsPageToken() async throws {
  let first = """
    {"nextPageToken":"next","files":[
      {"id":"1","name":"A.txt","mimeType":"text/plain","size":"3"}
    ]}
    """
  let second = """
    {"files":[
      {"id":"2","name":"Photos","mimeType":"application/vnd.google-apps.folder"}
    ]}
    """
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(status: 200, body: Data(first.utf8)),
    HTTPResponse(status: 200, body: Data(second.utf8)),
  ])
  let provider = GoogleDriveProvider(session: try session(transport))
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["A.txt", "Photos"])
  #expect(items[1].isDirectory)
}

@Test func googleDriveResumableUploadSplitsAtEightMegabytes() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let size = 8 * 1024 * 1024 + 1
  try Data(repeating: 7, count: size).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)),
    HTTPResponse(status: 200, headers: ["Location": "https://upload.example.com/session"]),
    HTTPResponse(status: 308, headers: ["Range": "bytes=0-8388607"]),
    HTTPResponse(status: 201, body: Data(#"{"id":"new"}"#.utf8)),
  ])
  let provider = GoogleDriveProvider(session: try session(transport))
  let progress = Mutex<[Int64]>([])
  await provider.onProgress { completed, _ in progress.withLock { $0.append(completed) } }
  try await provider.connect()
  try await provider.write(try RemotePath("/large.bin"), from: file)
  #expect(progress.withLock { $0 } == [8 * 1024 * 1024, Int64(size)])
  let requests = transport.requests.withLock { $0 }
  #expect(requests[3].url?.query?.contains("uploadType=resumable") == true)
  #expect(transport.uploadRequests.withLock { $0.count } == 2)
  #expect(requests[4].httpBody?.count == 8 * 1024 * 1024)
  #expect(requests[5].httpBody?.count == 1)
  #expect(
    requests[5].value(forHTTPHeaderField: "Content-Range") == "bytes 8388608-8388608/8388609")
}

@Test func googleDriveSmallUploadUsesMultipartEndpoint() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("hello".utf8).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"id":"new"}"#.utf8)),
  ])
  let provider = GoogleDriveProvider(session: try session(transport))
  let progress = Mutex<[Int64]>([])
  await provider.onProgress { completed, _ in progress.withLock { $0.append(completed) } }
  try await provider.connect()
  try await provider.write(try RemotePath("/small.txt"), from: file)
  #expect(progress.withLock { $0 } == [5])
  let request = try #require(transport.requests.withLock { $0.last })
  #expect(request.url?.query?.contains("uploadType=multipart") == true)
  #expect(transport.uploadRequests.withLock { $0.count } == 1)
}

@Test func oneDriveUploadSessionSplitsAtThreeHundredTwentyKiB() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let size = 320 * 1024 + 3
  try Data(repeating: 8, count: size).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200),
    HTTPResponse(status: 404),
    HTTPResponse(
      status: 200,
      body: Data(#"{"uploadUrl":"https://upload.example.com/session"}"#.utf8)),
    HTTPResponse(status: 202, body: Data(#"{"nextExpectedRanges":["327680-"]}"#.utf8)),
    HTTPResponse(status: 201, body: Data(#"{"id":"new"}"#.utf8)),
  ])
  let provider = OneDriveProvider(
    session: try session(transport), transport: transport,
    uploadSessionThreshold: 1, chunkSize: 320 * 1024)
  try await provider.connect()
  do {
    try await provider.write(try RemotePath("/large.bin"), from: file)
  } catch {
    let requests = transport.requests.withLock {
      $0.map { "\($0.httpMethod ?? "GET") \($0.url?.absoluteString ?? "")" }
    }
    Issue.record("OneDrive 上传失败：\(error)，请求：\(requests)")
    throw error
  }
  let uploads = transport.requests.withLock {
    $0.filter { $0.url?.host == "upload.example.com" }
  }
  #expect(transport.uploadRequests.withLock { $0.count } == 2)
  #expect(uploads.map(\.httpBody?.count) == [320 * 1024, 3])
  #expect(uploads[0].value(forHTTPHeaderField: "Content-Range") == "bytes 0-327679/327683")
  #expect(uploads[1].value(forHTTPHeaderField: "Content-Range") == "bytes 327680-327682/327683")
  #expect(uploads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
}

@Test func oneDriveRefusesToReplaceAnExistingName() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("new".utf8).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200),
    HTTPResponse(status: 200, body: Data(#"{"id":"old","name":"A.txt"}"#.utf8)),
  ])
  let provider = OneDriveProvider(session: try session(transport), transport: transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(try RemotePath("/A.txt"), from: file)
  }
}

@Test func googleDriveRefusesToUploadOverAnExistingName() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("new".utf8).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)),
    HTTPResponse(
      status: 200, body: Data(#"{"files":[{"id":"1"}]}"#.utf8)),
  ])
  let provider = GoogleDriveProvider(session: try session(transport))
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(try RemotePath("/A.txt"), from: file)
  }
  #expect(transport.requests.withLock { $0.count } == 3)
}

@Test func dropboxFollowsCursorAndRejectsMissingRange() async throws {
  let first = """
    {"entries":[{".tag":"file","name":"A.txt","size":3}],
     "cursor":"cursor-2","has_more":true}
    """
  let second = """
    {"entries":[{".tag":"folder","name":"Photos"}],
     "cursor":"cursor-3","has_more":false}
    """
  let transport = FakeTransport(
    [
      HTTPResponse(status: 200, body: Data("{}".utf8)),
      HTTPResponse(status: 200, body: Data(first.utf8)),
      HTTPResponse(status: 200, body: Data(second.utf8)),
    ], streamResponse: HTTPResponse(status: 200))
  let provider = DropboxProvider(session: try session(transport))
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["A.txt", "Photos"])
  #expect(items[1].isDirectory)

  await #expect(throws: RemoteError.protocolError) {
    _ = try await provider.read(try RemotePath("/A.txt"), range: 0..<1)
  }
}

@Test func dropboxUploadSessionHandlesLastPartialChunk() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let size = 16 * 1024 * 1024 + 3
  try Data(repeating: 9, count: size).write(to: file)
  let transport = FakeTransport([
    HTTPResponse(status: 200, body: Data("{}".utf8)),
    HTTPResponse(status: 200, body: Data(#"{"session_id":"session"}"#.utf8)),
    HTTPResponse(status: 200),
    HTTPResponse(status: 200),
    HTTPResponse(status: 200, body: Data(#"{"name":"large.bin"}"#.utf8)),
  ])
  let provider = DropboxProvider(
    session: try session(transport), uploadSessionThreshold: 1, chunkSize: 8 * 1024 * 1024)
  try await provider.connect()
  try await provider.write(try RemotePath("/large.bin"), from: file)
  #expect(transport.uploadRequests.withLock { $0.count } == 3)
  let requests = transport.requests.withLock { $0 }
  #expect(requests[1].httpBody?.count == 8 * 1024 * 1024)
  #expect(requests[2].httpBody?.count == 8 * 1024 * 1024)
  #expect(requests[3].httpBody?.count == 3)
}
