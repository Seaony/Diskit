import Core
import Foundation
import Synchronization
import Testing

@testable import ChinaWebDrive

private actor XunleiCoverageHTTP: HTTPTransport {
  private var replies: [HTTPResponse]
  private var streams: [HTTPResponse]
  var requests: [URLRequest] = []
  var streamRequests: [URLRequest] = []
  init(_ replies: [HTTPResponse], streams: [HTTPResponse] = []) {
    self.replies = replies
    self.streams = streams
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !replies.isEmpty else { throw RemoteError.protocolError }
    return replies.removeFirst()
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    streamRequests.append(request)
    guard !streams.isEmpty else { throw RemoteError.protocolError }
    let response = streams.removeFirst()
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream {
        if !response.body.isEmpty { $0.yield(response.body) }
        $0.finish()
      })
  }
}

private func coverageReply(_ value: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(value.utf8))
}
private func coverageSession(_ http: XunleiCoverageHTTP) -> XunleiSession {
  XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http)
}

@Test(arguments: [false, true])
func xunleiExpiredDownloadLinkRefreshesDetailWithoutLeakingAuth(missingReplacement: Bool)
  async throws
{
  let replacement =
    missingReplacement
    ? #"{"id":"movie","name":"movie","kind":"drive#file","size":2}"#
    : #"{"id":"movie","name":"movie","kind":"drive#file","size":2,"medias":[{"link":{"url":"https://cdn.example.invalid/new"}}]}"#
  let http = XunleiCoverageHTTP(
    [
      coverageReply("{}"),
      coverageReply(#"{"files":[{"id":"movie","name":"movie","kind":"drive#file","size":2}]}"#),
      coverageReply(
        #"{"id":"movie","name":"movie","kind":"drive#file","size":2,"medias":[{"link":{"url":"https://cdn.example.invalid/old"}}]}"#
      ),
      coverageReply(replacement),
    ], streams: [HTTPResponse(status: 401), HTTPResponse(status: 200, body: Data([1, 2]))])
  let provider = XunleiProvider(session: coverageSession(http))
  try await provider.connect()
  if missingReplacement {
    await #expect(throws: XunleiError.invalidResponse) {
      _ = try await provider.read(RemotePath("/movie"), range: nil)
    }
  } else {
    var bytes = Data()
    for try await chunk in try await provider.read(RemotePath("/movie"), range: nil) {
      bytes.append(chunk)
    }
    #expect(bytes == Data([1, 2]))
  }
  let streams = await http.streamRequests
  #expect(
    streams.compactMap { $0.url?.lastPathComponent }
      == (missingReplacement ? ["old"] : ["old", "new"]))
  #expect(streams.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
}

@Test func xunleiRootAndCachedAncestorRespectDisconnect() async throws {
  let http = XunleiCoverageHTTP([
    coverageReply("{}"),
    coverageReply(#"{"files":[{"id":"folder","name":"dir","kind":"drive#folder"}]}"#),
    coverageReply(#"{"files":[{"id":"child","name":"child","kind":"drive#file","size":5}]}"#),
  ])
  let provider = XunleiProvider(session: coverageSession(http))
  try await provider.connect()
  #expect(try await provider.stat(RemotePath("/")).isDirectory)
  try await provider.makeDirectory(RemotePath("/"))
  _ = try await provider.list(RemotePath("/"))
  #expect(try await provider.stat(RemotePath("/dir/child")).size == 5)
  try await provider.move(RemotePath("/dir/child"), to: RemotePath("/dir/child"))
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await provider.remove(RemotePath("/"), recursive: true)
  }
  await #expect(throws: RemoteError.posix(EISDIR)) {
    _ = try await provider.read(RemotePath("/dir"), range: nil)
  }
  #expect(await http.requests.count == 3)
  await provider.disconnect()
  await #expect(throws: RemoteError.notConnected) { _ = try await provider.stat(RemotePath("/")) }
}

private struct RejectUnexpectedCoverageUpload: XunleiVendorUploader {
  func upload(
    from localFile: URL, size: Int64, parameters: XunleiUploadParameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    Issue.record("该分支不应开始发送文件")
    throw RemoteError.protocolError
  }
}

@Test(arguments: ["complete", "renamed", "unsupported", "missing-key", "small-part"])
func xunleiUploadTicketBranchesPreserveProgressAndCleanup(mode: String) async throws {
  let name = mode == "renamed" ? "other" : "file"
  let phase = mode == "complete" ? "PHASE_TYPE_COMPLETE" : "PHASE_TYPE_RUNNING"
  let vendor = mode == "unsupported" ? "OTHER" : "PROVIDER_ALIYUN"
  let key = mode == "missing-key" ? "" : "local"
  let partSize = mode == "small-part" ? 1 : 102400
  let ticket = """
    {"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","name":"\(name)","kind":"drive#file","size":3,"phase":"\(phase)"},"resumable":{"provider":"\(vendor)","params":{"endpoint":"oss-cn-hangzhou.aliyuncs.com","access_key_id":"local","access_key_secret":"local","bucket":"local","key":"\(key)","part_size":\(partSize)}}}
    """
  let http = XunleiCoverageHTTP([
    coverageReply("{}"), coverageReply(#"{"files":[]}"#), coverageReply(ticket),
    coverageReply("{}"),
  ])
  let provider = XunleiProvider(
    session: coverageSession(http), uploader: RejectUnexpectedCoverageUpload())
  let progress = Mutex<[(Int64, Int64)]>([])
  await provider.onProgress { current, total in progress.withLock { $0.append((current, total)) } }
  let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data([1, 2, 3]).write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  try await provider.connect()
  if mode == "complete" {
    try await provider.write(RemotePath("/file"), from: source)
    #expect(progress.withLock { $0.count } == 1)
    #expect(progress.withLock { $0.last?.0 } == 3)
    #expect(progress.withLock { $0.last?.1 } == 3)
  } else if mode == "renamed" {
    await #expect(throws: RemoteError.posix(EEXIST)) {
      try await provider.write(RemotePath("/file"), from: source)
    }
  } else if mode == "unsupported" {
    await #expect(throws: XunleiError.unsupportedUploadProvider) {
      try await provider.write(RemotePath("/file"), from: source)
    }
  } else {
    await #expect(throws: XunleiError.invalidResponse) {
      try await provider.write(RemotePath("/file"), from: source)
    }
  }
  let requests = await http.requests
  #expect(requests.filter { $0.httpMethod == "PATCH" }.count == (mode == "complete" ? 0 : 1))
  if mode != "complete" { #expect(requests.last?.url?.path.hasSuffix("/new/trash") == true) }
}

@Test(arguments: [false, true])
func xunleiWrappedDirectoryCreationValidatesReturnedName(renamed: Bool) async throws {
  let name = renamed ? "other" : "dir"
  let http = XunleiCoverageHTTP([
    coverageReply("{}"), coverageReply(#"{"files":[]}"#),
    coverageReply("{\"file\":{\"id\":\"new\",\"name\":\"\(name)\",\"kind\":\"drive#folder\"}}"),
    coverageReply("{}"),
  ])
  let provider = XunleiProvider(session: coverageSession(http))
  try await provider.connect()
  if renamed {
    await #expect(throws: RemoteError.posix(EEXIST)) {
      try await provider.makeDirectory(RemotePath("/dir"))
    }
  } else {
    try await provider.makeDirectory(RemotePath("/dir"))
  }
  #expect(await http.requests.filter { $0.httpMethod == "PATCH" }.count == (renamed ? 1 : 0))
}

@Test(arguments: ["not_found", "too_many_requests", "not_allowed", "invalid_params"])
func xunleiBusinessFailurePreservesActionableError(reason: String) async throws {
  let http = XunleiCoverageHTTP([coverageReply("{\"error\":\"\(reason)\"}")])
  let session = coverageSession(http)
  let expected: RemoteError =
    switch reason {
    case "not_found": .posix(ENOENT)
    case "too_many_requests": .rateLimited
    case "not_allowed": .posix(EACCES)
    default: .posix(EINVAL)
    }
  await #expect(throws: expected) { _ = try await session.request(method: "GET", path: "about") }
}

@Test func xunleiInputAndRefreshValidationNeverSendsInvalidRequests() async throws {
  let emptyHTTP = XunleiCoverageHTTP([])
  let empty = XunleiSession(credentials: XunleiCredentials(accessToken: ""), transport: emptyHTTP)
  await #expect(throws: XunleiError.invalidCredentials) { try await empty.connect() }
  let session = coverageSession(emptyHTTP)
  await #expect(throws: XunleiError.invalidResponse) {
    _ = try await session.request(
      method: "GET", url: URL(string: "https://untrusted.example.invalid/about")!)
  }
  await #expect(throws: XunleiError.invalidResponse) {
    _ = try await session.download(
      URL(string: "https://user:pass@cdn.example.invalid/file")!, range: nil)
  }
  #expect(await emptyHTTP.requests.isEmpty)
  #expect(await emptyHTTP.streamRequests.isEmpty)
  let rejectedHTTP = XunleiCoverageHTTP([HTTPResponse(status: 401)])
  let rejected = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { _ in XunleiCredentials(accessToken: "") }, transport: rejectedHTTP)
  await #expect(throws: XunleiError.loginRequired) {
    try await rejected.request(method: "GET", path: "about")
  }
  #expect(await rejectedHTTP.requests.count == 1)
}
