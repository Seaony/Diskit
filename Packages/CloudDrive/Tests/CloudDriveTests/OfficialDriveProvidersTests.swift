import Core
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class ProviderSecrets: SecretStore, Sendable {
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

private final class ProviderFakeTransport: HTTPTransport, Sendable {
  let responses = Mutex<[HTTPResponse]>([])
  let requests = Mutex<[URLRequest]>([])
  let streamResponse: HTTPResponse

  init(_ responses: [HTTPResponse], streamResponse: HTTPResponse? = nil) {
    self.responses.withLock { $0 = responses }
    self.streamResponse = streamResponse ?? HTTPResponse(status: 200)
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return responses.withLock {
      guard !$0.isEmpty else { return HTTPResponse(status: 500) }
      return $0.removeFirst()
    }
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.withLock { $0.append(request) }
    return HTTPStreamResponse(
      response: streamResponse,
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data("range".utf8))
        continuation.finish()
      })
  }
}

private func providerSession(_ transport: ProviderFakeTransport) throws -> OAuthSession {
  let secrets = ProviderSecrets()
  let token = OAuthToken(
    accessToken: "access", refreshToken: "refresh",
    expiresAt: Date().addingTimeInterval(3_600))
  try secrets.write(JSONEncoder().encode(token), for: "oauth")
  return OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "client", clientSecret: "secret",
      authorizationURL: URL(string: "https://example.com/authorize")!,
      tokenURL: URL(string: "https://example.com/token")!,
      redirectURI: "kayoi://oauth/test", scopes: []),
    secretKey: "oauth", secrets: secrets, transport: transport)
}

private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
  var data = Data()
  for try await chunk in stream { data.append(chunk) }
  return data
}

@Test func baiduListsOnlyTheConfiguredAppDirectoryAndReadsRanges() async throws {
  let list = """
    {
      "errno":0,
      "list":[{
        "fs_id":42,
        "path":"/apps/Kayoi/照片/a.jpg",
        "server_filename":"a.jpg",
        "size":9,
        "server_mtime":1700000000,
        "isdir":0
      }]
    }
    """
  let transport = ProviderFakeTransport(
    [
      HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":7,"vip_type":0}"#.utf8)),
      HTTPResponse(status: 200, body: Data(list.utf8)),
      HTTPResponse(
        status: 200,
        body: Data(
          #"{"errno":0,"list":[{"fs_id":42,"path":"/apps/Kayoi/照片/a.jpg","server_filename":"a.jpg","size":9,"server_mtime":1700000000,"isdir":0,"dlink":"https://download.example.com/a.jpg"}]}"#
            .utf8)),
    ], streamResponse: HTTPResponse(status: 206))
  let provider = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(transport), transport: transport)
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/照片"))
  #expect(items.map(\.path.value) == ["/照片/a.jpg"])

  let stream = try await provider.read(try RemotePath("/照片/a.jpg"), range: 2..<7)
  var data = Data()
  for try await chunk in stream { data.append(chunk) }
  #expect(data == Data("range".utf8))
  let streamRequest = try #require(transport.requests.withLock { $0.last })
  #expect(streamRequest.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
  #expect(streamRequest.value(forHTTPHeaderField: "Range") == "bytes=2-6")
}

@Test func baiduUploadUsesOfficialBlocksAndRefusesExistingTargets() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let blockSize = 4 * 1024 * 1024
  try Data(repeating: 5, count: blockSize + 1).write(to: file)
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":7,"vip_type":0}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"errno":-9}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"errno":0,"uploadid":"upload","block_list":[0,1]}"#.utf8)),
    HTTPResponse(
      status: 200, body: Data(#"{"error_code":0,"host":"https://upload.example.com"}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"md5":"a"}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"md5":"b"}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"fs_id":123}"#.utf8)),
  ])
  let provider = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(transport), transport: transport)
  try await provider.connect()
  try await provider.write(try RemotePath("/large.bin"), from: file)
  let uploads = transport.requests.withLock {
    $0.filter { $0.url?.path == "/rest/2.0/pcs/superfile2" }
  }
  #expect(uploads.count == 2)
  #expect(uploads[0].httpBody!.count > blockSize)
  #expect(uploads[1].httpBody!.count < 2_000)
}

@Test func baiduRejectsAmbiguousPathLookups() async throws {
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":7,"vip_type":0}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"errno":0,"list":[{"fs_id":1,"path":"/apps/Kayoi/a","server_filename":"a"},{"fs_id":2,"path":"/apps/Kayoi/a","server_filename":"a"}]}"#
          .utf8)),
  ])
  let provider = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(transport), transport: transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    _ = try await provider.stat(try RemotePath("/a"))
  }
}

@Test func drive115PaginatesAndUploadsConfiguredSlices() async throws {
  let firstEntries = (0..<1_150).map {
    #"{"fid":"\#($0)","aid":"1","fc":"0","fn":"D\#($0)","uet":1700000000}"#
  }.joined(separator: ",")
  let firstPage = """
    {"state":true,"code":0,"count":1151,"data":[\(firstEntries)]}
    """
  let secondPage = """
    {"state":true,"code":0,"count":1151,
     "data":[{"fid":"last","aid":"1","fc":"1","fn":"A.txt","fs":3,"uet":1700000001}]}
    """
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("hello".utf8).write(to: file)
  let transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"user_id":1,"user_name":"N","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(firstPage.utf8)),
    HTTPResponse(status: 200, body: Data(secondPage.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"state":false,"code":20009}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"status":1,"code":0,"pick_code":"pick","target":"U_1_0","bucket":"fhnfile","endpoint":"https://up-file.115.com","object":"uploads/file","callback":{"callback":"callback-data","callback_var":"callback-vars"}}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"endpoint":"https://up-file.115.com","AccessKeyId":"key","AccessKeySecret":"secret","SecurityToken":"token"}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(status: 200, headers: ["ETag": "\"one\""]),
    HTTPResponse(status: 200, headers: ["ETag": "\"two\""]),
    HTTPResponse(status: 200, headers: ["ETag": "\"three\""]),
    HTTPResponse(status: 200),
  ])
  let session = try providerSession(transport)
  let provider = Drive115Provider(
    session: session, transport: transport, multipartThreshold: 1, partSize: 2)
  try await provider.connect()
  let listed = try await provider.list(try RemotePath("/"))
  #expect(listed.count == 1_151)
  try await provider.write(try RemotePath("/large.bin"), from: file)
  let requests = transport.requests.withLock { $0 }
  let parts = requests.filter {
    $0.url?.path == "/uploads/file" && $0.url?.query?.contains("partNumber") == true
  }
  #expect(parts.count == 3)
  #expect(parts.map(\.httpBody?.count) == [2, 2, 1])
  #expect(
    parts.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("OSS key:") == true
    })
}

@Test func drive123PaginatesAndUsesServerSliceSize() async throws {
  let firstFiles = (0..<100).map {
    #"{"fileId":\#($0),"filename":"F\#($0)","type":0,"size":1,"parentFileId":0,"trashed":0}"#
  }.joined(separator: ",")
  let firstPage = """
    {"code":0,"message":"ok",
     "data":{"lastFileId":99,"fileList":[\(firstFiles)]}}
    """
  let secondPage = """
    {"code":0,"message":"ok",
     "data":{"lastFileId":-1,
       "fileList":[{"fileId":101,"filename":"Last","type":1,"size":0,"parentFileId":0,"trashed":0}]}}
    """
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("hello".utf8).write(to: file)
  let transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(firstPage.utf8)),
    HTTPResponse(status: 200, body: Data(secondPage.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"fileID":0,"reuse":false,"preuploadID":"pre","sliceSize":2,"servers":["https://upload.example.com"]}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"code":0,"message":"ok","data":null}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"code":0,"message":"ok","data":null}"#.utf8)),
    HTTPResponse(status: 200, body: Data(#"{"code":0,"message":"ok","data":null}"#.utf8)),
    HTTPResponse(
      status: 200, body: Data(#"{"code":0,"data":{"completed":true,"fileID":9}}"#.utf8)),
  ])
  let provider = Drive123Provider(session: try providerSession(transport), transport: transport)
  try await provider.connect()
  let listed = try await provider.list(try RemotePath("/"))
  #expect(listed.count == 101)
  try await provider.write(try RemotePath("/large.bin"), from: file)
  let slices = transport.requests.withLock {
    $0.filter { $0.url?.path == "/upload/v2/file/slice" }
  }
  #expect(slices.count == 3)
  let sizes = slices.compactMap(\.httpBody?.count)
  #expect(sizes.count == 3)
  #expect(sizes[0] == sizes[1])
  #expect(sizes[0] > sizes[2])
  #expect(
    slices.allSatisfy {
      $0.value(forHTTPHeaderField: "Platform") == "open_platform"
    })
}

@Test func drive123RefreshesBusinessAuthenticationAndRejectsDuplicateNames() async throws {
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"code":401}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"access_token":"new","refresh_token":"refresh","expires_in":3600}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":1,"filename":"dup","type":0,"size":1,"parentFileId":0,"trashed":0},{"fileId":2,"filename":"dup","type":0,"size":1,"parentFileId":0,"trashed":0}]}}"#
          .utf8)),
  ])
  let provider = Drive123Provider(session: try providerSession(transport), transport: transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    _ = try await provider.stat(try RemotePath("/dup"))
  }
}

@Test func drive123UploadCompletionStopsAtItsLimit() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1]).write(to: file)
  let transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"fileID":0,"reuse":false,"preuploadID":"pre","sliceSize":1,"servers":["https://upload.example.com"]}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"code":0,"data":null}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"code":0,"data":{"completed":false,"fileID":0}}"#.utf8)),
  ])
  let provider = Drive123Provider(
    session: try providerSession(transport), transport: transport, completionPollLimit: 1)
  try await provider.connect()
  do {
    try await provider.write(try RemotePath("/new.bin"), from: file)
    Issue.record("上传完成轮询超时没有触发")
  } catch let error as RemoteError {
    let requests = transport.requests.withLock {
      $0.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" }
    }
    if error != .posix(ETIMEDOUT) {
      Issue.record("上传完成轮询返回 \(error)，请求：\(requests)")
    }
    #expect(error == .posix(ETIMEDOUT))
  } catch {
    let requests = transport.requests.withLock {
      $0.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" }
    }
    Issue.record("上传完成轮询返回了错误类型：\(error)，请求：\(requests)")
  }
}

@Test func businessErrorsUseExactCodesAndDoNotTreatEveryConflictAsDuplicate() {
  #expect(
    CloudDriveSupport.mapHTTP(HTTPResponse(status: 403))
      == RemoteError.posix(EACCES))
  #expect(
    CloudDriveSupport.mapHTTP(HTTPResponse(status: 409, body: Data(#"{"error":"other"}"#.utf8)))
      == RemoteError.posix(EIO))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 409, body: Data(#"{"error_summary":"path/insufficient_space"}"#.utf8)))
      == RemoteError.posix(ENOSPC))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 409, body: Data(#"{"error_summary":"path/no_write_permission"}"#.utf8)))
      == RemoteError.posix(EACCES))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 409, body: Data(#"{"error_summary":"path/conflict/file"}"#.utf8)))
      == RemoteError.posix(EEXIST))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 409, body: Data(#"{"code": 5060}"#.utf8)))
      == RemoteError.posix(EEXIST))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 403, body: Data(#"{"errno": -8}"#.utf8)))
      == RemoteError.posix(EEXIST))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(
        status: 403,
        body: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)))
      == RemoteError.rateLimited)
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 200, body: Data(#"{"state":0,"code":40140117}"#.utf8)))
      == RemoteError.rateLimited)
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 200, body: Data(#"{"state": 0, "code": 5113}"#.utf8)))
      == RemoteError.rateLimited)
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 507, body: Data(#"{"error":{"code":"quotaLimitReached"}}"#.utf8)))
      == RemoteError.posix(ENOSPC))
  #expect(
    CloudDriveSupport.mapHTTP(
      HTTPResponse(status: 200, body: Data(#"{"errno": -10}"#.utf8)))
      == RemoteError.posix(ENOSPC))
}

@Test func drive115NumericBusinessStateRefreshesAuthentication() async throws {
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"state":0,"code":40140116}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"access_token":"new","refresh_token":"refresh","expires_in":3600}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":1,"code":0,"data":{"user_id":1,"user_name":"N","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
          .utf8)),
  ])
  let provider = Drive115Provider(session: try providerSession(transport), transport: transport)

  try await provider.connect()
  let paths = transport.requests.withLock { $0.compactMap(\.url?.path) }
  #expect(paths == ["/open/user/info", "/token", "/open/user/info"])
}

@Test func baiduPreservesLoginAfterASecondUnauthorizedResponse() async throws {
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":1}"#.utf8)),
    HTTPResponse(status: 401),
    HTTPResponse(
      status: 200,
      body: Data(#"{"access_token":"new","refresh_token":"refresh","expires_in":3600}"#.utf8)),
    HTTPResponse(status: 401),
  ])
  let session = try providerSession(transport)
  let provider = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: session, transport: transport)
  try await provider.connect()

  await #expect(throws: OAuthDriveError.loginRequired) {
    _ = try await provider.stat(try RemotePath("/a.txt"))
  }
  #expect(try await session.hasToken())
}

@Test func emptyRangesReturnWithoutNetworkForAllProviders() async throws {
  let baiduTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":1}"#.utf8))
  ])
  let baidu = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(baiduTransport), transport: baiduTransport)
  try await baidu.connect()
  let baiduBefore = baiduTransport.requests.withLock { $0.count }
  #expect(
    try await collect(baidu.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(baiduTransport.requests.withLock { $0.count } == baiduBefore)

  let drive115Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"user_id":1,"user_name":"N","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
          .utf8))
  ])
  let drive115 = Drive115Provider(
    session: try providerSession(drive115Transport), transport: drive115Transport)
  try await drive115.connect()
  let drive115Before = drive115Transport.requests.withLock { $0.count }
  #expect(
    try await collect(drive115.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(drive115Transport.requests.withLock { $0.count } == drive115Before)

  let drive123Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8))
  ])
  let drive123 = Drive123Provider(
    session: try providerSession(drive123Transport), transport: drive123Transport)
  try await drive123.connect()
  let drive123Before = drive123Transport.requests.withLock { $0.count }
  #expect(
    try await collect(drive123.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(drive123Transport.requests.withLock { $0.count } == drive123Before)

  let oneDriveTransport = ProviderFakeTransport([HTTPResponse(status: 200)])
  let oneDrive = OneDriveProvider(
    session: try providerSession(oneDriveTransport), transport: oneDriveTransport)
  try await oneDrive.connect()
  let oneDriveBefore = oneDriveTransport.requests.withLock { $0.count }
  #expect(
    try await collect(oneDrive.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(oneDriveTransport.requests.withLock { $0.count } == oneDriveBefore)

  let googleTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8))
  ])
  let google = GoogleDriveProvider(session: try providerSession(googleTransport))
  try await google.connect()
  let googleBefore = googleTransport.requests.withLock { $0.count }
  #expect(
    try await collect(google.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(googleTransport.requests.withLock { $0.count } == googleBefore)

  let dropboxTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data("{}".utf8))
  ])
  let dropbox = DropboxProvider(session: try providerSession(dropboxTransport))
  try await dropbox.connect()
  let dropboxBefore = dropboxTransport.requests.withLock { $0.count }
  #expect(
    try await collect(dropbox.read(try RemotePath("/empty"), range: 4..<4)) == Data())
  #expect(dropboxTransport.requests.withLock { $0.count } == dropboxBefore)
}

@Test func googleWorkspaceNativeFilesRejectMediaReads() async throws {
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"files":[{"id":"doc","name":"Doc","mimeType":"application/vnd.google-apps.document"}]}"#
          .utf8)),
  ])
  let provider = GoogleDriveProvider(session: try providerSession(transport))
  try await provider.connect()

  await #expect(throws: RemoteError.unsupported) {
    _ = try await provider.read(try RemotePath("/Doc"), range: nil)
  }
  #expect(transport.requests.withLock { $0.count } == 2)
}

@Test func providerPreflightOnlyTreatsExplicitNotFoundAsMissing() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("test".utf8).write(to: file)

  let baiduTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":1}"#.utf8)),
    HTTPResponse(status: 403),
  ])
  let baidu = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(baiduTransport), transport: baiduTransport)
  try await baidu.connect()
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await baidu.write(try RemotePath("/denied.bin"), from: file)
  }

  let drive115Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":1,"code":0,"data":{"user_id":1,"user_name":"N","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"state":0,"code":990001}"#.utf8)),
  ])
  let drive115 = Drive115Provider(
    session: try providerSession(drive115Transport), transport: drive115Transport)
  try await drive115.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await drive115.makeDirectory(try RemotePath("/existing"))
  }

  let drive123Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(status: 500),
  ])
  let drive123 = Drive123Provider(
    session: try providerSession(drive123Transport), transport: drive123Transport)
  try await drive123.connect()
  await #expect(throws: RemoteError.http(500)) {
    try await drive123.move(
      try RemotePath("/source"), to: try RemotePath("/destination"))
  }

  let oneDriveTransport = ProviderFakeTransport([
    HTTPResponse(status: 200),
    HTTPResponse(status: 403),
  ])
  let oneDrive = OneDriveProvider(
    session: try providerSession(oneDriveTransport), transport: oneDriveTransport)
  try await oneDrive.connect()
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await oneDrive.write(try RemotePath("/denied.bin"), from: file)
  }

  let googleTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(status: 409, body: Data(#"{"error":{"code":409}}"#.utf8)),
  ])
  let google = GoogleDriveProvider(session: try providerSession(googleTransport))
  try await google.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await google.makeDirectory(try RemotePath("/conflict"))
  }

  let dropboxTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data("{}".utf8)),
    HTTPResponse(status: 409, body: Data(#"{"error":{}}"#.utf8)),
  ])
  let dropbox = DropboxProvider(session: try providerSession(dropboxTransport))
  try await dropbox.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await dropbox.move(
      try RemotePath("/source"), to: try RemotePath("/destination"))
  }
}

@Test func drive123UsesTheOfficialTenBillionByteLimit() async throws {
  try Drive123Provider.validateFileSize(Drive123Provider.maximumFileSize)
  #expect(throws: RemoteError.posix(EFBIG)) {
    try Drive123Provider.validateFileSize(Drive123Provider.maximumFileSize + 1)
  }

  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  FileManager.default.createFile(atPath: file.path, contents: nil)
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: UInt64(Drive123Provider.maximumFileSize + 1))
  try handle.close()

  let transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#.utf8)),
  ])
  let provider = Drive123Provider(session: try providerSession(transport), transport: transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EFBIG)) {
    try await provider.write(try RemotePath("/too-large.bin"), from: file)
  }
}

@Test func baiduFetchesEveryThousandEntryPage() async throws {
  let firstEntries = (0..<1_000).map {
    #"{"fs_id":\#($0),"path":"/apps/Kayoi/file-\#($0)","server_filename":"file-\#($0)","size":1,"isdir":0}"#
  }.joined(separator: ",")
  let transport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":1}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(#"{"errno":0,"list":[\#(firstEntries)]}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"errno":0,"list":[{"fs_id":1000,"path":"/apps/Kayoi/last","server_filename":"last","size":1,"isdir":0}]}"#
          .utf8)),
  ])
  let provider = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(transport), transport: transport)
  try await provider.connect()

  let items = try await provider.list(try RemotePath("/"))
  #expect(items.count == 1_001)
  let starts: [String] = transport.requests.withLock {
    $0.compactMap { request -> String? in
      guard request.url?.path == "/rest/2.0/xpan/file" else { return nil }
      return URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "start" }?.value
    }
  }
  #expect(starts == ["0", "1000"])
}

@Test func removeUsesEachProvidersOfficialDeletionSemantics() async throws {
  let baiduTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"errno":0,"uk":1}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"errno":0,"list":[{"path":"/apps/Kayoi/a.txt","server_filename":"a.txt","size":1,"isdir":0}]}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"errno":0}"#.utf8)),
  ])
  let baidu = BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: "/apps/Kayoi", appID: "app"),
    session: try providerSession(baiduTransport), transport: baiduTransport)
  try await baidu.connect()
  try await baidu.remove(try RemotePath("/a.txt"), recursive: false)
  let baiduDelete = try #require(
    baiduTransport.requests.withLock {
      $0.last {
        $0.httpMethod == "POST"
          && $0.url?.path == "/rest/2.0/xpan/file"
          && String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("opera=delete")
      }
    })
  #expect(baiduDelete.httpMethod == "POST")

  let drive115Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"user_id":1,"user_name":"N","rt_space_info":{"all_total":{"size":100},"all_use":{"size":10}}}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"state":true,"code":0,"data":{"file_id":"15","file_name":"a.txt","file_category":"1","size_byte":1}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"state":true,"code":0}"#.utf8)),
  ])
  let drive115 = Drive115Provider(
    session: try providerSession(drive115Transport), transport: drive115Transport)
  try await drive115.connect()
  try await drive115.remove(try RemotePath("/a.txt"), recursive: false)
  #expect(
    drive115Transport.requests.withLock {
      $0.contains { $0.url?.path == "/open/ufile/delete" }
    })

  let drive123Transport = ProviderFakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"uid":1,"nickname":"N","headImage":"","spaceUsed":10,"spacePermanent":100,"spaceTemp":0}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"lastFileId":-1,"fileList":[{"fileId":15,"filename":"a.txt","type":0,"size":1,"parentFileId":0,"trashed":0}]}}"#
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"code":0,"data":{"fileID":15,"filename":"a.txt","type":0,"size":1,"parentFileID":0,"trashed":0}}"#
          .utf8)),
    HTTPResponse(status: 200, body: Data(#"{"code":0,"data":null}"#.utf8)),
  ])
  let drive123 = Drive123Provider(
    session: try providerSession(drive123Transport), transport: drive123Transport)
  try await drive123.connect()
  try await drive123.remove(try RemotePath("/a.txt"), recursive: false)
  #expect(
    drive123Transport.requests.withLock {
      $0.contains { $0.url?.path == "/api/v1/file/trash" }
    })

  let oneDriveTransport = ProviderFakeTransport([
    HTTPResponse(status: 200),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"id":"15","name":"a.txt","size":1,"lastModifiedDateTime":"2026-01-01T00:00:00Z"}"#
          .utf8)),
    HTTPResponse(status: 204),
  ])
  let oneDrive = OneDriveProvider(
    session: try providerSession(oneDriveTransport), transport: oneDriveTransport)
  try await oneDrive.connect()
  try await oneDrive.remove(try RemotePath("/a.txt"), recursive: false)
  let oneDriveDelete = try #require(oneDriveTransport.requests.withLock { $0.last })
  #expect(oneDriveDelete.httpMethod == "DELETE")
  #expect(oneDriveDelete.url?.host == "graph.microsoft.com")

  let googleTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data(#"{"user":{}}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"files":[{"id":"google-15","name":"a.txt","mimeType":"text/plain"}]}"#.utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{"id":"google-15","name":"a.txt","mimeType":"text/plain","size":"1"}"#.utf8)),
    HTTPResponse(status: 200, body: Data("{}".utf8)),
  ])
  let google = GoogleDriveProvider(session: try providerSession(googleTransport))
  try await google.connect()
  try await google.remove(try RemotePath("/a.txt"), recursive: false)
  let googleDelete = try #require(googleTransport.requests.withLock { $0.last })
  #expect(googleDelete.httpMethod == "PATCH")
  #expect(googleDelete.url?.path == "/drive/v3/files/google-15")
  let googleDeleteBody = try #require(googleDelete.httpBody)
  #expect(String(decoding: googleDeleteBody, as: UTF8.self) == #"{"trashed":true}"#)

  let dropboxTransport = ProviderFakeTransport([
    HTTPResponse(status: 200, body: Data("{}".utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        #"{".tag":"file","name":"a.txt","path_display":"/a.txt","size":1}"#.utf8)),
    HTTPResponse(status: 200, body: Data("{}".utf8)),
  ])
  let dropbox = DropboxProvider(session: try providerSession(dropboxTransport))
  try await dropbox.connect()
  try await dropbox.remove(try RemotePath("/a.txt"), recursive: false)
  #expect(
    dropboxTransport.requests.withLock {
      $0.contains { $0.url?.path == "/2/files/delete_v2" }
    })
}

@Test(arguments: ["115", "123"], [false, true])
func driveBusinessAuthFailurePreservesRefreshedLogin(_ kind: String, _ business: Bool) async throws
{
  let denied =
    business
    ? HTTPResponse(
      status: 200,
      body: Data((kind == "115" ? #"{"state":0,"code":40140116}"# : #"{"code":401}"#).utf8))
    : HTTPResponse(status: 401)
  let transport = ProviderFakeTransport([
    denied,
    HTTPResponse(
      status: 200,
      body: Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8)),
    denied,
  ])
  let session = try providerSession(transport)
  let provider: any RemoteFileProvider =
    kind == "115"
    ? Drive115Provider(session: session, transport: transport)
    : Drive123Provider(session: session, transport: transport)
  await #expect(throws: OAuthDriveError.loginRequired) { try await provider.connect() }
  #expect(try await session.hasToken())
  #expect(transport.requests.withLock { $0.count } == 3)
}
