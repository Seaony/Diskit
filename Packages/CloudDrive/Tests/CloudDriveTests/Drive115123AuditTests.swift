@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class AuditDriveHTTP: HTTPTransport, Sendable {
  let requests = Mutex<[URLRequest]>([])
  let reply: @Sendable (URLRequest) throws -> HTTPResponse
  init(_ reply: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.reply = reply }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return try reply(request)
  }
}

private func auditJSON(_ value: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(value.utf8))
}

private let audit115User =
  #"{"state":true,"data":{"user_id":1,"user_name":"Local","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
private let audit123User =
  #"{"code":0,"data":{"uid":1,"nickname":"Local","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#

private func auditSession(_ transport: any HTTPTransport) throws -> OAuthSession {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "local", refreshToken: "local", expiresAt: .distantFuture)),
    for: "account")
  return OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "local", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/auth")!,
      tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://local",
      scopes: []), secretKey: "account", secrets: secrets, transport: transport)
}

private func auditQuery(_ request: URLRequest, _ name: String) -> String? {
  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
    .first { $0.name == name }?.value
}

private func auditFormContains(_ request: URLRequest, _ name: String, _ value: String) -> Bool {
  String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    .contains("name=\"\(name)\"\r\n\r\n\(value)\r\n")
}

@Test(arguments: [false, true])
func drive115DuplicateNamesGetFinderStyleNamesAndTheirOwnID(listFirst: Bool) async throws {
  let http = AuditDriveHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return auditJSON(audit115User)
    case "/open/ufile/files":
      return auditJSON(
        #"{"state":true,"count":2,"data":[{"fid":"2","fc":"1","fn":"dup.txt","fs":2},{"fid":"1","fc":"1","fn":"dup.txt","fs":1}]}"#
      )
    case "/open/folder/get_info":
      let id = auditQuery(request, "file_id") ?? ""
      return auditJSON(
        "{\"state\":true,\"data\":{\"file_id\":\"\(id)\",\"file_name\":\"dup.txt\",\"file_category\":\"1\",\"size_byte\":\(id)}}"
      )
    case "/open/ufile/delete", "/open/ufile/update": return auditJSON(#"{"state":true}"#)
    default: return HTTPResponse(status: 404)
    }
  }
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  if listFirst {
    let items = try await provider.list(RemotePath("/"))
    #expect(items.map(\.path.value) == ["/dup (2).txt", "/dup.txt"])
    #expect(items.map(\.name) == ["dup (2).txt", "dup.txt"])
  }
  #expect(try await provider.stat(RemotePath("/dup (2).txt")).size == 2)
  try await provider.remove(RemotePath("/dup (2).txt"), recursive: false)
  let delete = try #require(
    http.requests.withLock { $0.last { $0.url?.path == "/open/ufile/delete" } })
  #expect(auditFormContains(delete, "file_ids", "2"))
  // 新建和显示名同名的条目按已存在处理
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/dup (2).txt"))
  }
  #expect(!http.requests.withLock { $0.contains { $0.url?.path == "/open/folder/add" } })
  // 改名按真实名字判断，改的是编号对应的那一份
  try await provider.move(RemotePath("/dup (2).txt"), to: RemotePath("/other.txt"))
  let update = try #require(
    http.requests.withLock { $0.last { $0.url?.path == "/open/ufile/update" } })
  #expect(auditFormContains(update, "file_id", "2"))
  #expect(auditFormContains(update, "file_name", "other.txt"))
}

@Test func drive115ReadReusesPickCodeAndDownloadURL() async throws {
  let clock = Mutex(Date(timeIntervalSince1970: 0))
  let links = Mutex(0)
  let downloads = Mutex(0)
  let http = AuditDriveHTTP { request in
    if request.url?.host == "cdn.example.invalid" {
      let count = downloads.withLock {
        $0 += 1
        return $0
      }
      // 第 3 次下载模拟地址过期
      if count == 3 { return HTTPResponse(status: 403) }
      #expect(request.url?.path == "/a\(links.withLock { $0 })")
      return HTTPResponse(status: 206, body: Data([1]))
    }
    switch request.url?.path {
    case "/open/user/info": return auditJSON(audit115User)
    case "/open/ufile/files":
      return auditJSON(
        #"{"state":true,"count":1,"data":[{"fid":"7","fc":"1","fn":"a.bin","fs":4,"pc":"pick7","uet":1}]}"#
      )
    case "/open/ufile/downurl":
      #expect(auditFormContains(request, "pick_code", "pick7"))
      let count = links.withLock {
        $0 += 1
        return $0
      }
      return auditJSON(
        "{\"state\":true,\"data\":{\"7\":{\"url\":{\"url\":\"https://cdn.example.invalid/a\(count)\"}}}}"
      )
    default:
      Issue.record("读文件不应再请求 \(request.url?.path ?? "")")
      return HTTPResponse(status: 404)
    }
  }
  let provider = Drive115Provider(
    session: try auditSession(http), transport: http, multipartThreshold: 1, partSize: 1,
    now: { clock.withLock { $0 } })
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  _ = try await provider.read(RemotePath("/a.bin"), range: 0..<1)
  _ = try await provider.read(RemotePath("/a.bin"), range: 1..<2)
  #expect(links.withLock { $0 } == 1)
  _ = try await provider.read(RemotePath("/a.bin"), range: 2..<3)
  #expect(links.withLock { $0 } == 2)
  #expect(downloads.withLock { $0 } == 4)
  clock.withLock { $0 += Drive115Provider.downloadLinkLifetime }
  _ = try await provider.read(RemotePath("/a.bin"), range: 3..<4)
  #expect(links.withLock { $0 } == 3)
}

@Test func drive123ReadReusesDownloadURLAndDuplicatesTargetTheirOwnID() async throws {
  let clock = Mutex(Date(timeIntervalSince1970: 0))
  let links = Mutex(0)
  let downloads = Mutex(0)
  let http = AuditDriveHTTP { request in
    if request.url?.host == "cdn.example.invalid" {
      let count = downloads.withLock {
        $0 += 1
        return $0
      }
      if count == 3 { return HTTPResponse(status: 403) }
      #expect(request.url?.path == "/a\(links.withLock { $0 })")
      return HTTPResponse(status: 206, body: Data([1]))
    }
    switch request.url?.path {
    case "/api/v1/user/info": return auditJSON(audit123User)
    case "/api/v2/file/list":
      return auditJSON(
        #"{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":8,"filename":"a.bin","type":0,"size":4,"parentFileId":0,"trashed":0},{"fileId":7,"filename":"a.bin","type":0,"size":4,"parentFileId":0,"trashed":0}]}}"#
      )
    case "/api/v1/file/download_info":
      #expect(auditQuery(request, "fileId") == "8")
      let count = links.withLock {
        $0 += 1
        return $0
      }
      return auditJSON(
        "{\"code\":0,\"data\":{\"downloadUrl\":\"https://cdn.example.invalid/a\(count)\"}}")
    case "/api/v1/file/detail":
      #expect(auditQuery(request, "fileID") == "8")
      return auditJSON(
        #"{"code":0,"data":{"fileID":8,"filename":"a.bin","type":0,"size":4,"parentFileID":0,"trashed":0}}"#
      )
    default:
      Issue.record("读文件不应再请求 \(request.url?.path ?? "")")
      return HTTPResponse(status: 404)
    }
  }
  let provider = Drive123Provider(
    session: try auditSession(http), transport: http, completionPollLimit: 1,
    completionDeadline: nil, now: { clock.withLock { $0 } })
  try await provider.connect()
  #expect(
    try await provider.list(RemotePath("/")).map(\.path.value) == ["/a (2).bin", "/a.bin"])
  _ = try await provider.read(RemotePath("/a (2).bin"), range: 0..<1)
  _ = try await provider.read(RemotePath("/a (2).bin"), range: 1..<2)
  #expect(links.withLock { $0 } == 1)
  _ = try await provider.read(RemotePath("/a (2).bin"), range: 2..<3)
  #expect(links.withLock { $0 } == 2)
  #expect(downloads.withLock { $0 } == 4)
  clock.withLock { $0 += Drive123Provider.downloadLinkLifetime }
  _ = try await provider.read(RemotePath("/a (2).bin"), range: 3..<4)
  #expect(links.withLock { $0 } == 3)
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/a (2).bin"))
  }
}

@Test func drive115SpaceRefreshesAfterConnection() async throws {
  let count = Mutex(0)
  let http = AuditDriveHTTP { request in
    guard request.url?.path == "/open/user/info" else { return HTTPResponse(status: 404) }
    let used = count.withLock {
      $0 += 1
      return $0 * 10
    }
    return auditJSON(
      "{\"state\":true,\"data\":{\"user_id\":1,\"user_name\":\"Local\",\"rt_space_info\":{\"all_total\":{\"size\":100},\"all_use\":{\"size\":\(used)}}}}"
    )
  }
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  #expect(try await provider.spaceInfo().used == 20)
  #expect(try await provider.spaceInfo().used == 30)
}

@Test(arguments: ["115", "123"])
func sameDirectoryRenameDoesNotIssueMove(kind: String) async throws {
  let http = AuditDriveHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return auditJSON(audit115User)
    case "/api/v1/user/info": return auditJSON(audit123User)
    case "/open/ufile/files":
      return auditJSON(
        #"{"state":true,"count":1,"data":[{"fid":"1","fc":"1","fn":"source","fs":1}]}"#)
    case "/api/v2/file/list":
      return auditJSON(
        #"{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":1,"filename":"source","type":0,"size":1,"parentFileId":0,"trashed":0}]}}"#
      )
    case "/open/ufile/update": return auditJSON(#"{"state":true,"code":0}"#)
    case "/api/v1/file/name": return auditJSON(#"{"code":0,"data":null}"#)
    default: return HTTPResponse(status: 404)
    }
  }
  let session = try auditSession(http)
  let provider: any RemoteFileProvider =
    kind == "115"
    ? Drive115Provider(session: session, transport: http)
    : Drive123Provider(session: session, transport: http)
  try await provider.connect()
  try await provider.move(RemotePath("/source"), to: RemotePath("/target"))
  #expect(!http.requests.withLock { $0.contains { $0.url?.path.hasSuffix("/move") == true } })
}

@Test(arguments: [203, 200])
func drive115UploadCallbackFailureNeverReportsSuccess(status: Int) async throws {
  let http = AuditDriveHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return auditJSON(audit115User)
    case "/open/ufile/files": return auditJSON(#"{"state":true,"count":0,"data":[]}"#)
    case "/open/upload/init":
      return auditJSON(
        #"{"state":true,"data":{"status":1,"bucket":"bucket","object":"object","callback":{"callback":"{}","callback_var":"{}"}}}"#
      )
    case "/open/upload/get_token":
      return auditJSON(
        #"{"state":true,"data":{"endpoint":"http://oss-cn-hangzhou.aliyuncs.com","AccessKeyId":"local","AccessKeySecret":"local","SecurityToken":"local"}}"#
      )
    case "/object":
      #expect(request.url?.scheme == "https")
      #expect(request.url?.host == "bucket.oss-cn-hangzhou.aliyuncs.com")
      return HTTPResponse(
        status: status, body: Data("<Error><Code>CallbackFailed</Code></Error>".utf8))
    default: return HTTPResponse(status: 404)
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1]).write(to: file)
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  await #expect(
    throws: RemoteError.failed(
      EIO, LF("115 网盘上传后确认失败：%@（HTTP %@）", "CallbackFailed", String(status)))
  ) {
    try await provider.write(RemotePath("/new"), from: file)
  }
}

@Test(arguments: [500, 200])
func drive123ChecksEverySliceBeforePublishing(status: Int) async throws {
  let http = AuditDriveHTTP { request in
    switch request.url?.path {
    case "/api/v1/user/info": return auditJSON(audit123User)
    case "/api/v2/file/list":
      return auditJSON(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#)
    case "/upload/v2/file/create":
      return auditJSON(
        #"{"code":0,"data":{"fileID":0,"reuse":false,"preuploadID":"local","sliceSize":1,"servers":["https://upload.example.invalid"]}}"#
      )
    case "/upload/v2/file/slice": return auditJSON(#"{"code":5060,"data":null}"#, status: status)
    default: return HTTPResponse(status: 404)
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1, 2]).write(to: file)
  let provider = Drive123Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  await #expect(throws: (any Error).self) {
    try await provider.write(RemotePath("/new"), from: file)
  }
  #expect(
    !http.requests.withLock { $0.contains { $0.url?.path == "/upload/v2/file/upload_complete" } })
  #expect(
    http.requests.withLock { $0.filter { $0.url?.path == "/upload/v2/file/slice" }.count } <= 3)
}

@Test(arguments: [
  "oss-cn-hangzhou.aliyuncs.com", "http://oss-cn-hangzhou.aliyuncs.com",
  "https://bucket.oss-cn-hangzhou.aliyuncs.com",
])
func drive115OSSSignatureIncludesRawObjectAndSortedSubresources(endpoint: String) throws {
  let credentials = Drive115Credentials(
    endpoint: endpoint, accessKeyID: "local", accessKeySecret: "secret", securityToken: "token",
    rate: nil)
  let signer = Drive115OSSSigner(credentials: credentials, bucket: "bucket")
  let request = try signer.request(
    method: "PUT", endpoint: endpoint, object: "目录//a b+", body: Data([1]),
    query: [
      URLQueryItem(name: "uploadId", value: "a+/?"), URLQueryItem(name: "partNumber", value: "2"),
    ], callback: nil, now: Date(timeIntervalSince1970: 0))
  #expect(request.url?.scheme == "https")
  #expect(request.url?.host == "bucket.oss-cn-hangzhou.aliyuncs.com")
  let url = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
  #expect(url.percentEncodedPath == "/%E7%9B%AE%E5%BD%95//a%20b%2B")
  #expect(url.percentEncodedQuery == "partNumber=2&uploadId=a%2B%2F%3F")
  #expect(
    request.value(forHTTPHeaderField: "Authorization") == "OSS local:y2MUhMr51JcK3iW2xG23+yOsI0o=")
}

@Test func drive115OSSCallbackHeadersEncodeJSONAndEmptySubresource() throws {
  let endpoint = "https://oss-cn-hangzhou.aliyuncs.com"
  let signer = Drive115OSSSigner(
    credentials: Drive115Credentials(
      endpoint: endpoint, accessKeyID: "local", accessKeySecret: "secret", securityToken: "token",
      rate: nil), bucket: "bucket")
  let callback = Drive115Callback(
    callback: #"{"callbackUrl":"https://example.invalid"}"#, callbackVar: #"{"x:uid":"1"}"#)
  let request = try signer.request(
    method: "POST", endpoint: endpoint, object: "file", body: Data(),
    query: [URLQueryItem(name: "uploads", value: "")], callback: callback,
    now: Date(timeIntervalSince1970: 0))
  #expect(
    Data(base64Encoded: request.value(forHTTPHeaderField: "x-oss-callback")!)
      == Data(callback.callback.utf8))
  #expect(
    Data(base64Encoded: request.value(forHTTPHeaderField: "x-oss-callback-var")!)
      == Data(callback.callbackVar.utf8))
  #expect(request.url?.query == "uploads=")
  #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
}

@Test func drive115FindsDuplicateAcrossShortPages() async throws {
  let http = AuditDriveHTTP { request in
    if request.url?.path == "/open/user/info" { return auditJSON(audit115User) }
    if request.url?.path == "/open/folder/get_info" {
      #expect(auditQuery(request, "file_id") == "1")
      return auditJSON(
        #"{"state":true,"data":{"file_id":"1","file_name":"dup","file_category":"1","size_byte":1}}"#)
    }
    guard request.url?.path == "/open/ufile/files" else { return HTTPResponse(status: 404) }
    let offset = auditQuery(request, "offset") ?? "0"
    return auditJSON(
      "{\"state\":true,\"count\":2,\"data\":[{\"fid\":\"\(offset)\",\"fc\":\"1\",\"fn\":\"dup\",\"fs\":1}]}"
    )
  }
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).map(\.path.value) == ["/dup", "/dup (2)"])
  #expect(try await provider.stat(RemotePath("/dup (2)")).path.value == "/dup (2)")
}

private actor Slow123CompletionHTTP: HTTPTransport {
  nonisolated let pollStarted = TestEvent()
  nonisolated let pollRelease = TestEvent()
  var cancelled = false
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    switch request.url?.path {
    case "/api/v1/user/info": return auditJSON(audit123User)
    case "/api/v2/file/list":
      return auditJSON(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#)
    case "/upload/v2/file/create":
      return auditJSON(
        #"{"code":0,"data":{"fileID":0,"reuse":false,"preuploadID":"local","sliceSize":1,"servers":["https://upload.example.invalid"]}}"#
      )
    case "/upload/v2/file/slice": return auditJSON(#"{"code":0,"data":null}"#)
    case "/upload/v2/file/upload_complete":
      pollStarted.signal()
      do { try await pollRelease.wait() } catch {
        cancelled = true
        throw error
      }
      return auditJSON(#"{"code":0,"data":{"completed":false,"fileID":0}}"#)
    default: return HTTPResponse(status: 404)
    }
  }
}

@Test func drive123CompletionDeadlineCancelsSlowPollRequest() async throws {
  let http = Slow123CompletionHTTP()
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1]).write(to: file)
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(
    interval: .seconds(1),
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
  let provider = Drive123Provider(
    session: try auditSession(http), transport: http, completionPollLimit: 1,
    completionDeadline: deadline)
  try await provider.connect()
  let upload = Task { try await provider.write(RemotePath("/new"), from: file) }
  try await http.pollStarted.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(1))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await upload.value }
  #expect(await http.cancelled)
}
