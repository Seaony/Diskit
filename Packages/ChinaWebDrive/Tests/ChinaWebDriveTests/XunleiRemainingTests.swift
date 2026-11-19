import AlibabaCloudOSS
@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import ChinaWebDrive

private actor XunleiReplies: HTTPTransport {
  let handler: @Sendable (URLRequest) async throws -> HTTPResponse
  var requests: [URLRequest] = []
  init(_ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
    self.handler = handler
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try await handler(request)
  }
}

private func xlReply(_ json: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(json.utf8))
}

@Test func xunleiEmptyErrorDoesNotRejectSuccess() async throws {
  let http = XunleiReplies { _ in xlReply(#"{"error":"  ","quota":{"limit":100,"usage":2}}"#) }
  let session = XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http)
  #expect(try await session.request(method: "GET", path: "about").status == 200)
}

@Test(arguments: [401, 403, 200])
func xunleiVerificationDoesNotRefreshLogin(status: Int) async throws {
  let refreshes = Mutex(0)
  let http = XunleiReplies { _ in
    xlReply(
      #"{"error":"captcha_required","error_description":"verification_required"}"#, status: status)
  }
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { old in
      refreshes.withLock { $0 += 1 }
      return old
    }, transport: http)
  await #expect(throws: XunleiError.verificationRequired) {
    _ = try await session.request(method: "GET", path: "about")
  }
  #expect(refreshes.withLock { $0 } == 0)
  #expect(!XunleiError.verificationRequired.requiresLogin)
}

@Test func xunleiConcurrentUnauthorizedResponsesShareRefresh() async throws {
  let refreshes = Mutex(0)
  let rejected = TestEvent()
  let oldRequests = Mutex(0)
  let http = XunleiReplies { request in
    if request.value(forHTTPHeaderField: "Authorization") == "Token old" {
      if oldRequests.withLock({ $0 += 1; return $0 }) == 10 { rejected.signal() }
      try await rejected.wait()
      return HTTPResponse(status: 401)
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token new")
    return xlReply("{}")
  }
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { _ in
      refreshes.withLock { $0 += 1 }
      return XunleiCredentials(accessToken: "new")
    }, transport: http)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<10 {
      group.addTask { _ = try await session.request(method: "GET", path: "about") }
    }
    try await group.waitForAll()
  }
  #expect(refreshes.withLock { $0 } == 1)
}

@Test func xunleiForbiddenPermissionDoesNotForceLogin() async throws {
  let refreshes = Mutex(0)
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { old in
      refreshes.withLock { $0 += 1 }
      return old
    }, transport: XunleiReplies { _ in HTTPResponse(status: 403) })
  await #expect(throws: RemoteError.http(403)) {
    _ = try await session.request(method: "GET", path: "about")
  }
  #expect(refreshes.withLock { $0 } == 0)
}

@Test func xunleiPartFileCopiesOnlyBoundedRangeAndCleansUp() throws {
  let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let bytes = Data((0..<(XunleiPartFile.bufferSize * 3)).map { UInt8(truncatingIfNeeded: $0) })
  try bytes.write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  var part: XunleiPartFile? = try XunleiPartFile(
    source: source, offset: 11, length: Int64(bytes.count - 23))
  let url = try #require(part?.url)
  #expect(try Data(contentsOf: url) == bytes.subdata(in: 11..<(bytes.count - 12)))
  #expect(XunleiPartFile.bufferSize == 128 * 1024)
  part = nil
  #expect(!FileManager.default.fileExists(atPath: url.path))
  #expect(
    throws: RemoteError.failed(
      EIO, LF("本地文件提前读完，还差 %lld 字节，文件可能在上传期间被改动", Int64(1)))
  ) {
    _ = try XunleiPartFile(source: source, offset: Int64(bytes.count), length: 1)
  }
}

@Test func xunleiFilenameCannotInvalidateLogin() async throws {
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "local"),
    transport: XunleiReplies { _ in
      xlReply(#"{"files":[{"name":"unauthorized token expired.txt"}],"error":""}"#)
    })
  #expect(try await session.request(method: "GET", path: "files").status == 200)
}

private let oldXLListing =
  #"{"files":[{"id":"old-id","name":"old","kind":"drive#file","size":1}],"next_page_token":""}"#
private let newXLListing =
  #"{"files":[{"id":"new-id","name":"new","kind":"drive#file","size":2}],"next_page_token":""}"#

@Test func xunleiMutationFailureInvalidatesCachedDirectory() async throws {
  let mutationAttempted = Mutex(false)
  let http = XunleiReplies { request in
    if request.url?.path.hasSuffix("/about") == true { return xlReply("{}") }
    if request.httpMethod == "PATCH" {
      mutationAttempted.withLock { $0 = true }
      return HTTPResponse(status: 500)
    }
    return mutationAttempted.withLock { $0 } ? xlReply(#"{"files":[]}"#) : xlReply(oldXLListing)
  }
  let provider = XunleiProvider(
    session: XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http))
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  await #expect(throws: RemoteError.http(500)) {
    try await provider.remove(RemotePath("/old"), recursive: false)
  }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/old"))
  }
}

@Test func xunleiLateListingCannotRefillOlderCache() async throws {
  let started = AsyncStream<Void>.makeStream()
  let gate = AsyncStream<Void>.makeStream()
  let count = Mutex(0)
  let http = XunleiReplies { request in
    if request.url?.path.hasSuffix("/about") == true { return xlReply("{}") }
    let number = count.withLock {
      $0 += 1
      return $0
    }
    if number == 1 {
      started.continuation.yield(())
      started.continuation.finish()
      for await _ in gate.stream { break }
      return xlReply(oldXLListing)
    }
    return xlReply(newXLListing)
  }
  let provider = XunleiProvider(
    session: XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http))
  try await provider.connect()
  let first = Task { try await provider.list(RemotePath("/")) }
  for await _ in started.stream { break }
  #expect(try await provider.list(RemotePath("/")).map(\.name) == ["new"])
  gate.continuation.yield(())
  gate.continuation.finish()
  #expect(try await first.value.map(\.name) == ["old"])
  #expect(try await provider.stat(RemotePath("/new")).size == 2)
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/old"))
  }
}

@Test func xunleiDuplicateIDsAreReportedInsteadOfAmbiguousCache() async throws {
  let http = XunleiReplies { request in
    if request.url?.path.hasSuffix("/about") == true { return xlReply("{}") }
    return xlReply(
      #"{"files":[{"id":"same","name":"a","kind":"drive#file","size":1},{"id":"same","name":"b","kind":"drive#file","size":2}]}"#
    )
  }
  let provider = XunleiProvider(
    session: XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http))
  try await provider.connect()
  await #expect(throws: XunleiError.invalidResponse) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test func xunleiServerFailureDoesNotRefreshEvenWithTokenText() async throws {
  let refreshes = Mutex(0)
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { old in
      refreshes.withLock { $0 += 1 }
      return old
    }, transport: XunleiReplies { _ in xlReply(#"{"error":"invalid_token"}"#, status: 500) })
  await #expect(
    throws: RemoteError.failed(EIO, LF("迅雷云盘返回错误：%@（HTTP %@）", "invalid_token", String(500)))
  ) {
    _ = try await session.request(method: "GET", path: "about")
  }
  #expect(refreshes.withLock { $0 } == 0)
}

private struct CompletedVendorUpload: XunleiVendorUploader {
  func upload(
    from localFile: URL, size: Int64, parameters: XunleiUploadParameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {}
}

@Test(arguments: [false, true])
func xunleiCompletionPollingTracksProgressRatherThanRequestCount(progresses: Bool) async throws {
  let clock = ManualTestClock()
  let waiting = TestEvent()
  let blocked = TestEvent()
  let details = Mutex(0)
  let trashed = Mutex(false)
  let http = XunleiReplies { request in
    let path = request.url?.path ?? ""
    if path.hasSuffix("/about") { return xlReply("{}") }
    if request.httpMethod == "PATCH" {
      trashed.withLock { $0 = true }
      return xlReply("{}")
    }
    if request.httpMethod == "POST", path.hasSuffix("/files") {
      return xlReply(
        #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","name":"file","kind":"drive#file","size":1,"phase":"PHASE_TYPE_RUNNING"},"resumable":{"provider":"PROVIDER_ALIYUN","params":{"endpoint":"https://oss-cn-hangzhou.aliyuncs.com","access_key_id":"local","access_key_secret":"local","bucket":"local","key":"local"}}}"#
      )
    }
    if path.hasSuffix("/files/new") {
      let count = details.withLock {
        $0 += 1
        return $0
      }
      let phase: String
      if progresses {
        clock.advance(by: .seconds(1))
        phase =
          count == 1
          ? "PHASE_TYPE_PENDING" : count == 2 ? "PHASE_TYPE_RUNNING" : "PHASE_TYPE_COMPLETE"
      } else {
        if count == 3 {
          waiting.signal()
          try await blocked.wait()
        }
        clock.advance(by: .seconds(1))
        phase = "PHASE_TYPE_RUNNING"
      }
      return xlReply(
        "{\"id\":\"new\",\"name\":\"file\",\"kind\":\"drive#file\",\"size\":1,\"phase\":\"\(phase)\"}"
      )
    }
    return xlReply(#"{"files":[]}"#)
  }
  let session = XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http)
  let provider = XunleiProvider(
    session: session, uploader: CompletedVendorUpload(), uploadPollInterval: .zero,
    makeUploadDeadline: {
      HTTPProgressDeadline(interval: .milliseconds(2500),
        clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
    })
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data([1]).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  if progresses {
    try await provider.write(RemotePath("/file"), from: file)
    #expect(!trashed.withLock { $0 })
    #expect(details.withLock { $0 } == 3)
  } else {
    let operation = Task { try await provider.write(RemotePath("/file"), from: file) }
    try await waiting.wait()
    await clock.waitForSleepRequests(1)
    clock.advance(by: .seconds(2))
    do {
      try await operation.value
      Issue.record("没有进展的上传完成轮询应超时")
    } catch {
      let failure = error as NSError
      #expect(failure.domain == NSPOSIXErrorDomain)
      #expect(failure.code == Int(ETIMEDOUT))
    }
    #expect(trashed.withLock { $0 })
  }
}

@Test func xunleiSDKWrappedNetworkErrorKeepsPOSIXMeaning() {
  let wrapped = ClientError(
    code: "ResponseError", message: "local", innerError: URLError(.timedOut))
  let mapped = AliyunOSSXunleiUploader.map(wrapped) as NSError
  #expect(mapped.domain == NSPOSIXErrorDomain)
  #expect(mapped.code == Int(ETIMEDOUT))
  #expect(
    AliyunOSSXunleiUploader.map(
      ClientError(code: "ResponseError", message: "local", innerError: CancellationError()))
      is CancellationError)
  #expect(
    AliyunOSSXunleiUploader.map(CocoaError(.fileWriteOutOfSpace)) as? RemoteError == .posix(ENOSPC))
  #expect(
    AliyunOSSXunleiUploader.map(CocoaError(.fileReadNoSuchFile)) as? RemoteError == .posix(ENOENT))

}

@Test func xunleiMalformedListingFailsWithoutKeepingStaleEntries() async throws {
  let count = Mutex(0)
  let http = XunleiReplies { request in
    if request.url?.path.hasSuffix("/about") == true { return xlReply("{}") }
    let number = count.withLock {
      $0 += 1
      return $0
    }
    if number == 1 { return xlReply(oldXLListing) }
    if number == 2 {
      return xlReply(#"{"files":[{"id":"bad","name":"","kind":"drive#file","size":1}]}"#)
    }
    return xlReply(#"{"files":[]}"#)
  }
  let provider = XunleiProvider(
    session: XunleiSession(credentials: XunleiCredentials(accessToken: "local"), transport: http))
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  do {
    _ = try await provider.list(RemotePath("/"))
    Issue.record("含坏条目的目录必须明确失败，不能静默跳过")
  } catch {}
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/old"))
  }
  #expect(count.withLock { $0 } == 3)
}
