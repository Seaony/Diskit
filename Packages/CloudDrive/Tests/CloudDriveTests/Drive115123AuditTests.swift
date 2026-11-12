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

@Test(arguments: [false, true])
func drive115RejectsAmbiguousNamesBeforeAnyMutation(listFirst: Bool) async throws {
  let http = AuditDriveHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return auditJSON(audit115User)
    case "/open/ufile/files":
      return auditJSON(
        #"{"state":true,"count":2,"data":[{"fid":"1","fc":"1","fn":"dup","fs":1},{"fid":"2","fc":"1","fn":"dup","fs":2}]}"#
      )
    default: return HTTPResponse(status: 404)
    }
  }
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  if listFirst { #expect(try await provider.list(RemotePath("/")).count == 2) }
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.remove(RemotePath("/dup"), recursive: false)
  }
  #expect(
    !http.requests.withLock {
      $0.contains {
        $0.url?.path == "/open/ufile/delete" || $0.url?.path == "/open/folder/get_info"
      }
    })
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
  await #expect(throws: RemoteError.posix(EIO)) {
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
    guard request.url?.path == "/open/ufile/files" else { return HTTPResponse(status: 404) }
    let offset =
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
        $0.name == "offset"
      }?.value ?? "0"
    return auditJSON(
      "{\"state\":true,\"count\":2,\"data\":[{\"fid\":\"\(offset)\",\"fc\":\"1\",\"fn\":\"dup\",\"fs\":1}]}"
    )
  }
  let provider = Drive115Provider(session: try auditSession(http), transport: http)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).count == 2)
  await #expect(throws: RemoteError.posix(EEXIST)) {
    _ = try await provider.stat(RemotePath("/dup"))
  }
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
