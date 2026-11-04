import Core
import Foundation
import Synchronization
import Testing

@testable import ChinaWebDrive

private actor ScriptHTTP: HTTPTransport {
  private var replies: [HTTPResponse]
  private var streamReplies: [HTTPResponse]
  private(set) var requests: [URLRequest] = []
  private(set) var streamRequests: [URLRequest] = []

  init(_ replies: [HTTPResponse], streams: [HTTPResponse] = []) {
    self.replies = replies
    streamReplies = streams
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !replies.isEmpty else {
      Issue.record("未预期的请求 \(request.url?.absoluteString ?? "")")
      throw RemoteError.protocolError
    }
    return replies.removeFirst()
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    streamRequests.append(request)
    guard !streamReplies.isEmpty else {
      Issue.record("未预期的流请求 \(request.url?.absoluteString ?? "")")
      throw RemoteError.protocolError
    }
    let response = streamReplies.removeFirst()
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream { continuation in
        if !response.body.isEmpty { continuation.yield(response.body) }
        continuation.finish()
      })
  }
}

private actor RecordingXunleiUploader: XunleiVendorUploader {
  private let failure: RemoteError?
  private(set) var calls: [(URL, Int64, XunleiUploadParameters, Data)] = []

  init(failure: RemoteError? = nil) {
    self.failure = failure
  }

  func upload(
    from localFile: URL,
    size: Int64,
    parameters: XunleiUploadParameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    let data = try Data(contentsOf: localFile)
    calls.append((localFile, size, parameters, data))
    if let failure { throw failure }
    progress?(size, size)
  }
}

private func response(_ json: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(json.utf8))
}

private let mobileRoute = response(
  #"{"success":true,"code":"0000","data":{"routePolicyList":[{"modName":"personal","httpsUrl":"https://personal-kd-njs.yun.139.com/hcy","hashName":"sha256"}]}}"#
)

private func mobileSession(_ http: ScriptHTTP) -> MobileCloudSession {
  MobileCloudSession(
    credentials: MobileCloudCredentials(phone: "13800138000", token: "Y2xvdWQ="),
    transport: http)
}

private func temporaryFile(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try data.write(to: url)
  return url
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}

@Test func mobileCloudSignerMatchesMitGoldenVector() throws {
  let body =
    Data(#"{"名称":"测试","描述":"这是一个纯中文的请求体"}"#.utf8)
  #expect(
    MobileCloudSession.sign(
      body: body, timestamp: "2026-03-08 06:07:08", random: "6MRRtXXLhDKknje9")
      == "BBB03BD8A54CD841106E9ADD008AA3FA")
  #expect(
    ChinaWebSupport.percentEncodeJavaScript("中文 space+'()!*~-._")
      == "%E4%B8%AD%E6%96%87%20space%2B'()!*~-._")
}

@Test func mobileCloudPaginatesAndUsesRecordedHeaders() async throws {
  let first = response(
    #"{"success":true,"code":"0000","data":{"items":[{"fileId":"f1","name":"一","parentFileId":"/","size":3,"type":"file","updatedAt":"2026-11-04T08:00:00Z"}],"nextPageCursor":"p2"}}"#
  )
  let second = response(
    #"{"success":true,"code":"0000","data":{"items":[{"fileId":"d2","name":"目录","parentFileId":"/","size":0,"type":"folder","updatedAt":"1762243200000"}],"nextPageCursor":null}}"#
  )
  let http = ScriptHTTP([mobileRoute, first, second])
  let provider = MobileCloudProvider(session: mobileSession(http))
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["一", "目录"])
  #expect(items[1].isDirectory)
  let requests = await http.requests
  let listRequests = requests.filter { $0.url?.path.hasSuffix("/file/list") == true }
  #expect(listRequests.count == 2)
  #expect(try requestBody(listRequests[0])["parentFileId"] as? String == "/")
  #expect(
    (try requestBody(listRequests[1])["pageInfo"] as? [String: Any])?["pageCursor"] as? String
      == "p2")
  #expect(
    listRequests.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == "Basic Y2xvdWQ="
        && $0.value(forHTTPHeaderField: "Caller") == "web"
    })
  let timestamp = try #require(listRequests[0].value(forHTTPHeaderField: "mcloud-sign"))
  #expect(timestamp.split(separator: ",").count == 3)
  #expect(
    timestamp.range(
      of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},[A-Za-z0-9]{16},[A-F0-9]{32}$"#,
      options: .regularExpression) != nil)
}

@Test func mobileCloudRefreshesOnceAndRepeatsRoute() async throws {
  let calls = Mutex(0)
  let refreshed = MobileCloudCredentials(phone: "13800138000", token: "bmV3")
  let http = ScriptHTTP([
    response(#"{"success":false,"code":"9008","message":"token expired"}"#, status: 401),
    mobileRoute,
  ])
  let session = MobileCloudSession(
    credentials: MobileCloudCredentials(phone: "13800138000", token: "b2xk"),
    refresh: { rejected in
      #expect(rejected.token == "b2xk")
      calls.withLock { $0 += 1 }
      return refreshed
    }, transport: http)
  try await session.connect()
  #expect(calls.withLock { $0 } == 1)
  #expect(await http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic bmV3")
}

@Test func mobileCloudSpaceUsesAccountEndpointAndUserDomain() async throws {
  let space = response(
    #"{"success":true,"code":"0000","data":{"diskSize":"1000","freeDiskSize":"250"}}"#)
  let http = ScriptHTTP([mobileRoute, space])
  let session = MobileCloudSession(
    credentials: MobileCloudCredentials(
      phone: "13800138000", token: "Y2xvdWQ=", userDomainID: "domain-1"),
    transport: http)
  let provider = MobileCloudProvider(session: session)
  try await provider.connect()
  let routeRequest = try #require(await http.requests.first)
  #expect(
    ((try requestBody(routeRequest)["userInfo"] as? [String: Any])?["userDomainId"] as? String)
      == "domain-1")
  let value = try await provider.spaceInfo()
  #expect(value == SpaceInfo(total: 1000, used: 750))
  let request = try #require(await http.requests.last)
  #expect(request.url?.path == "/user/disk/getPersonalDiskInfo")
  #expect(try requestBody(request)["userDomainId"] as? String == "domain-1")
}

@Test func mobileCloudRangeValidatesContentRangeAndDoesNotSendAuthToCDN() async throws {
  let list = response(
    #"{"success":true,"code":"0000","data":{"items":[{"fileId":"f1","name":"movie.bin","size":100,"type":"file","updatedAt":"1762243200000"}],"nextPageCursor":null}}"#
  )
  let download = response(
    #"{"success":true,"code":"0000","data":{"url":"https://cdn.example.com/movie?sign=ok"}}"#
  )
  let stream = HTTPResponse(
    status: 206, headers: ["Content-Range": "bytes 10-19/100"], body: Data(repeating: 7, count: 10))
  let http = ScriptHTTP([mobileRoute, list, download], streams: [stream])
  let provider = MobileCloudProvider(session: mobileSession(http))
  try await provider.connect()
  var result = Data()
  for try await data in try await provider.read(try RemotePath("/movie.bin"), range: 10..<20) {
    result.append(data)
  }
  #expect(result.count == 10)
  let request = try #require(await http.streamRequests.first)
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
  #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
}

@Test func mobileCloudUploadUsesServerPartBoundariesAndFinishes() async throws {
  let file = try temporaryFile(Data([1, 2, 3]))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(
    #"{"success":true,"code":"0000","data":{"items":[],"nextPageCursor":null}}"#)
  let create = response(
    #"{"success":true,"code":"0000","data":{"fileId":"new","fileName":"upload.bin","uploadId":"u1","rapidUpload":false,"exist":false,"partInfos":[{"partNumber":2,"partSize":1,"uploadUrl":"https://upload.example.com/2"},{"partNumber":1,"partSize":2,"uploadUrl":"https://upload.example.com/1"}]}}"#
  )
  let complete = response(#"{"success":true,"code":"0000","data":{}}"#)
  let http = ScriptHTTP([
    mobileRoute, empty, create, HTTPResponse(status: 200), HTTPResponse(status: 200), complete,
  ])
  let progress = Mutex<[(Int64, Int64)]>([])
  let provider = MobileCloudProvider(session: mobileSession(http), partSize: 2)
  await provider.onProgress { loaded, total in progress.withLock { $0.append((loaded, total)) } }
  try await provider.connect()
  try await provider.write(try RemotePath("/upload.bin"), from: file)
  let requests = await http.requests
  let puts = requests.filter { $0.httpMethod == "PUT" }
  #expect(puts.map(\.httpBody) == [Data([1, 2]), Data([3])])
  #expect(
    puts.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == nil
        && $0.value(forHTTPHeaderField: "Cookie") == nil
    })
  let completeBody = try requestBody(requests.last!)
  #expect(completeBody["fileId"] as? String == "new")
  #expect(completeBody["uploadId"] as? String == "u1")
  #expect(
    completeBody["contentHash"] as? String
      == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
  let createRequest = try #require(
    requests.first { $0.url?.path.hasSuffix("/file/create") == true })
  let createBody = try requestBody(createRequest)
  #expect(createBody["contentHashAlgorithm"] as? String == "sha256")
  #expect(progress.withLock { $0 }.map(\.0) == [2, 3])
}

@Test func mobileCloudRequestsLaterUploadURLBatches() async throws {
  let file = try temporaryFile(Data([1, 2, 3]))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(
    #"{"success":true,"code":"0000","data":{"items":[],"nextPageCursor":null}}"#)
  let create = response(
    #"{"success":true,"code":"0000","data":{"fileId":"new","fileName":"upload.bin","uploadId":"u1","rapidUpload":false,"exist":false,"partInfos":[{"partNumber":1,"partSize":2,"uploadUrl":"https://upload.example.com/1"}]}}"#
  )
  let nextURL = response(
    #"{"success":true,"code":"0000","data":{"partInfos":[{"partNumber":2,"partSize":1,"uploadUrl":"https://upload.example.com/2"}]}}"#
  )
  let complete = response(#"{"success":true,"code":"0000","data":{}}"#)
  let http = ScriptHTTP([
    mobileRoute, empty, create, HTTPResponse(status: 200), nextURL, HTTPResponse(status: 200),
    complete,
  ])
  let provider = MobileCloudProvider(
    session: mobileSession(http), partSize: 2, maxPartsPerURL: 1)
  try await provider.connect()
  try await provider.write(try RemotePath("/upload.bin"), from: file)
  let requests = await http.requests
  let uploadURLRequest = try #require(
    requests.first { $0.url?.path.hasSuffix("/file/getUploadUrl") == true })
  let body = try requestBody(uploadURLRequest)
  #expect(body["fileId"] as? String == "new")
  #expect((body["partInfos"] as? [[String: Any]])?.first?["partNumber"] as? Int == 2)
  #expect(requests.filter { $0.httpMethod == "PUT" }.count == 2)
}

@Test func mobileCloudExistingNameNeverUploadsOrRenames() async throws {
  let file = try temporaryFile(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let existing = response(
    #"{"success":true,"code":"0000","data":{"items":[{"fileId":"old","name":"same.txt","size":3,"type":"file","updatedAt":"1762243200000"}],"nextPageCursor":null}}"#
  )
  let http = ScriptHTTP([mobileRoute, existing])
  let provider = MobileCloudProvider(session: mobileSession(http))
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(try RemotePath("/same.txt"), from: file)
  }
  #expect(await http.requests.count == 2)
}

@Test func mobileCloudPartSplitHandlesZeroExactAndRemainder() throws {
  #expect(try MobileCloudProvider.splitForTesting(size: 0, partSize: 2).map(\.2) == [0])
  #expect(try MobileCloudProvider.splitForTesting(size: 4, partSize: 2).map(\.2) == [2, 2])
  #expect(try MobileCloudProvider.splitForTesting(size: 5, partSize: 2).map(\.2) == [2, 2, 1])
}

@Test func mobileCloudMkdirMoveAndDeleteUseDocumentedOperations() async throws {
  let empty = response(
    #"{"success":true,"code":"0000","data":{"items":[],"nextPageCursor":null}}"#)
  let folderCreated = response(
    #"{"success":true,"code":"0000","data":{"fileId":"d","fileName":"dir","type":"folder"}}"#)
  let root = response(
    #"{"success":true,"code":"0000","data":{"items":[{"fileId":"d","name":"dir","size":0,"type":"folder","updatedAt":"1762243200000"},{"fileId":"x","name":"x","size":1,"type":"file","updatedAt":"1762243200000"}],"nextPageCursor":null}}"#
  )
  let moved = response(
    #"{"success":true,"code":"0000","data":{"fileId":"x","name":"y","parentFileId":"d"}}"#)
  let http = ScriptHTTP([
    mobileRoute, empty, folderCreated, root, root, empty, moved,
    response(#"{"success":true,"code":"0000","data":{"fileId":"x","name":"y"}}"#),
  ])
  let provider = MobileCloudProvider(session: mobileSession(http))
  try await provider.connect()
  try await provider.makeDirectory(try RemotePath("/dir"))
  try await provider.move(try RemotePath("/x"), to: try RemotePath("/dir/y"))
  let requests = await http.requests
  #expect(requests.contains { $0.url?.path.hasSuffix("/file/batchMove") == true })
  #expect(requests.contains { $0.url?.path.hasSuffix("/file/update") == true })
  #expect(try requestBody(requests.last!)["name"] as? String == "y")
}

private let xunleiAbout = response(
  #"{"kind":"drive#about","quota":{"limit":"1000","usage":"125"}}"#)

private func xunleiSession(_ http: ScriptHTTP) -> XunleiSession {
  XunleiSession(credentials: XunleiCredentials(accessToken: "session"), transport: http)
}

@Test func xunleiPaginatesAndUsesTokenHeaders() async throws {
  let first = response(
    #"{"kind":"drive#fileList","files":[{"id":"a","parent_id":"","name":"A","kind":"drive#file","size":2,"modified_time":"2026-11-04T08:00:00Z"}],"next_page_token":"next"}"#
  )
  let second = response(
    #"{"kind":"drive#fileList","files":[{"id":"b","name":"B","kind":"drive#folder","size":0,"modified_time":"1762243200"}],"next_page_token":""}"#
  )
  let http = ScriptHTTP([xunleiAbout, first, second])
  let provider = XunleiProvider(session: xunleiSession(http))
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["A", "B"])
  let requests = await http.requests
  let pages = requests.filter { $0.url?.path == "/drive/v1/files" }
  #expect(pages.count == 2)
  #expect(
    URLComponents(url: pages[1].url!, resolvingAgainstBaseURL: false)?.queryItems?
      .contains(URLQueryItem(name: "page_token", value: "next")) == true)
  #expect(
    pages.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == "Token session"
    })
}

@Test func xunleiRefreshesUnauthorizedRequestOnce() async throws {
  let http = ScriptHTTP([
    response(#"{"error":"invalid_token"}"#, status: 401),
    xunleiAbout,
  ])
  let calls = Mutex(0)
  let session = XunleiSession(
    credentials: XunleiCredentials(accessToken: "old"),
    refresh: { rejected in
      #expect(rejected.accessToken == "old")
      calls.withLock { $0 += 1 }
      return XunleiCredentials(accessToken: "new", spaceAuthorization: "space")
    }, transport: http)
  try await session.connect()
  #expect(calls.withLock { $0 } == 1)
  let last = try #require(await http.requests.last)
  #expect(last.value(forHTTPHeaderField: "Authorization") == "Token new")
  #expect(last.value(forHTTPHeaderField: "Space-Authorization") == "space")
}

@Test func xunleiRangeUsesDetailLinkWithoutLeakingLoginHeaders() async throws {
  let list = response(
    #"{"files":[{"id":"a","name":"movie.bin","kind":"drive#file","size":100,"modified_time":"1762243200"}],"next_page_token":""}"#
  )
  let detail = response(
    #"{"id":"a","name":"movie.bin","kind":"drive#file","size":100,"web_content_link":"https://cdn.example.com/movie?sign=ok"}"#
  )
  let stream = HTTPResponse(
    status: 206, headers: ["Content-Range": "bytes 2-5/100"], body: Data([2, 3, 4, 5]))
  let http = ScriptHTTP([xunleiAbout, list, detail], streams: [stream])
  let provider = XunleiProvider(session: xunleiSession(http))
  try await provider.connect()
  var result = Data()
  for try await bytes in try await provider.read(try RemotePath("/movie.bin"), range: 2..<6) {
    result.append(bytes)
  }
  #expect(result == Data([2, 3, 4, 5]))
  let request = try #require(await http.streamRequests.first)
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-5")
  #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(request.value(forHTTPHeaderField: "Space-Authorization") == nil)
  #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
}

@Test func xunleiUploadUsesAliyunMultipartWithoutSendingLoginToVendor() async throws {
  let file = try temporaryFile(Data(repeating: 7, count: 200 * 1024))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(#"{"files":[],"next_page_token":""}"#)
  let created = response(
    #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","parent_id":"","name":"upload.bin","kind":"drive#file","phase":"PHASE_TYPE_RUNNING","size":204800},"resumable":{"provider":"PROVIDER_ALIYUN","params":{"endpoint":"https://oss-cn-hangzhou.aliyuncs.com","region":"cn-hangzhou","access_key_id":"ak","access_key_secret":"sk","security_token":"sts","bucket":"bucket","key":"object-key","part_size":"102400"}}}"#
  )
  let final = response(
    #"{"id":"new","name":"upload.bin","kind":"drive#file","phase":"PHASE_TYPE_COMPLETE","size":204800}"#
  )
  let http = ScriptHTTP([xunleiAbout, empty, created, final])
  let uploader = RecordingXunleiUploader()
  let provider = XunleiProvider(
    session: xunleiSession(http), uploader: uploader)
  try await provider.connect()
  #expect(provider.capabilities.canWrite)
  try await provider.write(try RemotePath("/upload.bin"), from: file)

  let calls = await uploader.calls
  #expect(calls.count == 1)
  #expect(calls[0].1 == 204800)
  #expect(calls[0].2.endpoint.absoluteString == "https://oss-cn-hangzhou.aliyuncs.com")
  #expect(calls[0].2.bucket == "bucket")
  #expect(calls[0].2.key == "object-key")
  #expect(calls[0].2.partSize == 102400)
  #expect(calls[0].3.count == 204800)
  let requests = await http.requests
  let create = try #require(
    requests.first { $0.url?.path == "/drive/v1/files" && $0.httpMethod == "POST" })
  let body = try requestBody(create)
  #expect(
    (body["resumable"] as? [String: Any])?["supported_providers"] as? [String]
      == ["PROVIDER_ALIYUN"])
  #expect(body["upload_type"] as? String == "UPLOAD_TYPE_RESUMABLE")
  #expect(create.value(forHTTPHeaderField: "Authorization") == "Token session")
  #expect(requests.count == 4)
}

@Test func xunleiUploadFailureTrashesOnlyTheNewFile() async throws {
  let file = try temporaryFile(Data("x".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(#"{"files":[],"next_page_token":""}"#)
  let created = response(
    #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","name":"upload.bin","kind":"drive#file","phase":"PHASE_TYPE_RUNNING","size":1},"resumable":{"provider":"PROVIDER_ALIYUN","params":{"endpoint":"https://oss-cn-hangzhou.aliyuncs.com","access_key_id":"ak","access_key_secret":"sk","security_token":"sts","bucket":"bucket","key":"object-key","part_size":1048576}}}"#
  )
  let http = ScriptHTTP([
    xunleiAbout, empty, created, response(#"{"kind":"drive#batchResult"}"#),
  ])
  let uploader = RecordingXunleiUploader(failure: .protocolError)
  let provider = XunleiProvider(
    session: xunleiSession(http), uploader: uploader)
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.write(try RemotePath("/upload.bin"), from: file)
  }
  let deletion = try #require(
    await http.requests.first { $0.url?.path.hasSuffix("/files:batchDelete") == true })
  #expect(try requestBody(deletion)["ids"] as? [String] == ["new"])
}

@Test func xunleiUploadRejectsUntrustedVendorEndpointBeforeCallingSDK() async throws {
  let file = try temporaryFile(Data("x".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(#"{"files":[],"next_page_token":""}"#)
  let created = response(
    #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","name":"upload.bin","kind":"drive#file","phase":"PHASE_TYPE_RUNNING","size":1},"resumable":{"provider":"PROVIDER_ALIYUN","params":{"endpoint":"https://uploads.example.com","access_key_id":"ak","access_key_secret":"sk","security_token":"sts","bucket":"bucket","key":"object-key","part_size":1048576}}}"#
  )
  let http = ScriptHTTP([
    xunleiAbout, empty, created, response(#"{"kind":"drive#batchResult"}"#),
  ])
  let uploader = RecordingXunleiUploader()
  let provider = XunleiProvider(
    session: xunleiSession(http), uploader: uploader)
  try await provider.connect()
  await #expect(throws: XunleiError.invalidResponse) {
    try await provider.write(try RemotePath("/upload.bin"), from: file)
  }
  #expect(await uploader.calls.isEmpty)
  let deletion = try #require(
    await http.requests.first { $0.url?.path.hasSuffix("/files:batchDelete") == true })
  #expect(try requestBody(deletion)["ids"] as? [String] == ["new"])
}

@Test func xunleiUploadRejectsCreateErrorBeforeCallingSDK() async throws {
  let file = try temporaryFile(Data("x".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let empty = response(#"{"files":[],"next_page_token":""}"#)
  let created = response(
    #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"new","name":"upload.bin","kind":"drive#file","phase":"PHASE_TYPE_ERROR","size":1},"resumable":{"provider":"PROVIDER_ALIYUN","params":{"endpoint":"https://oss-cn-hangzhou.aliyuncs.com","access_key_id":"ak","access_key_secret":"sk","security_token":"sts","bucket":"bucket","key":"object-key","part_size":1048576}}}"#
  )
  let http = ScriptHTTP([
    xunleiAbout, empty, created, response(#"{"kind":"drive#batchResult"}"#),
  ])
  let uploader = RecordingXunleiUploader()
  let provider = XunleiProvider(
    session: xunleiSession(http), uploader: uploader)
  try await provider.connect()
  await #expect(throws: XunleiError.invalidResponse) {
    try await provider.write(try RemotePath("/upload.bin"), from: file)
  }
  #expect(await uploader.calls.isEmpty)
  let deletion = try #require(
    await http.requests.first { $0.url?.path.hasSuffix("/files:batchDelete") == true })
  #expect(try requestBody(deletion)["ids"] as? [String] == ["new"])
}

@Test func xunleiUploadRejectsExistingNameBeforeCreatingTask() async throws {
  let file = try temporaryFile(Data("x".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let existing = response(
    #"{"files":[{"id":"old","name":"same.bin","kind":"drive#file","size":1}],"next_page_token":""}"#
  )
  let http = ScriptHTTP([xunleiAbout, existing])
  let provider = XunleiProvider(
    session: xunleiSession(http), uploader: RecordingXunleiUploader())
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(try RemotePath("/same.bin"), from: file)
  }
  #expect(await http.requests.count == 2)
}

@Test func xunleiUploadPartSplitHandlesBoundaries() throws {
  let part = Int64(100 * 1024)
  #expect(try XunleiUploadPart.split(size: 0, requestedPartSize: part).isEmpty)
  #expect(
    try XunleiUploadPart.split(size: part * 2, requestedPartSize: part).map(\.length)
      == [part, part])
  #expect(
    try XunleiUploadPart.split(size: part * 2 + 1, requestedPartSize: part).map(\.length)
      == [part, part, 1])
}

@Test func xunleiExistingDirectoryNameFailsBeforeCreate() async throws {
  let existing = response(
    #"{"files":[{"id":"d","name":"same","kind":"drive#folder"}],"next_page_token":""}"#)
  let http = ScriptHTTP([xunleiAbout, existing])
  let provider = XunleiProvider(session: xunleiSession(http))
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(try RemotePath("/same"))
  }
  #expect(await http.requests.count == 2)
}

@Test func xunleiHTTPConflictMapsToEEXIST() async {
  let http = ScriptHTTP([HTTPResponse(status: 409)])
  let session = xunleiSession(http)
  await #expect(throws: RemoteError.http(409)) {
    _ = try await session.request(method: "GET", path: "about")
  }
  #expect(RemoteError.http(409).errno == EEXIST)
}

@Test func xunleiBusinessErrorsMapToPOSIX() async {
  let http = ScriptHTTP([
    response(#"{"error":"exists"}"#),
    response(#"{"error":"file_space_not_enough"}"#),
    response(#"{"error":"not_found"}"#),
  ])
  let session = xunleiSession(http)
  await #expect(throws: RemoteError.posix(EEXIST)) {
    _ = try await session.request(method: "GET", path: "about")
  }
  await #expect(throws: RemoteError.posix(ENOSPC)) {
    _ = try await session.request(method: "GET", path: "about")
  }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await session.request(method: "GET", path: "about")
  }
}

@Test func xunleiMkdirMoveAndTrashUseDocumentedBodies() async throws {
  let empty = response(#"{"files":[],"next_page_token":""}"#)
  let folder = response(
    #"{"id":"d","name":"dir","kind":"drive#folder","parent_id":""}"#)
  let root = response(
    #"{"files":[{"id":"d","name":"dir","kind":"drive#folder"},{"id":"x","name":"x","kind":"drive#file","size":1}],"next_page_token":""}"#
  )
  let moved = response(
    #"{"id":"x","name":"y","kind":"drive#file","parent_id":"d"}"#)
  let directory = response(
    #"{"files":[{"id":"x","name":"y","kind":"drive#file","parent_id":"d","size":1}],"next_page_token":""}"#
  )
  let http = ScriptHTTP([
    xunleiAbout, empty, folder, root, empty, moved, root, directory,
    response(#"{"kind":"drive#batchResult"}"#),
  ])
  let provider = XunleiProvider(session: xunleiSession(http))
  try await provider.connect()
  try await provider.makeDirectory(try RemotePath("/dir"))
  try await provider.move(try RemotePath("/x"), to: try RemotePath("/dir/y"))
  try await provider.remove(try RemotePath("/dir/y"), recursive: false)
  let requests = await http.requests
  let create = try #require(
    requests.first { $0.url?.path == "/drive/v1/files" && $0.httpMethod == "POST" })
  #expect(try requestBody(create)["kind"] as? String == "drive#folder")
  let move = try #require(requests.first { $0.url?.path.hasSuffix("/files/x/move") == true })
  let target = try #require(try requestBody(move)["to"] as? [String: Any])
  #expect(target["parent_id"] as? String == "d")
  #expect(target["name"] as? String == "y")
  let deletion = try #require(
    requests.first { $0.url?.path.hasSuffix("/files:batchDelete") == true })
  #expect(try requestBody(deletion)["ids"] as? [String] == ["x"])
}

@Test func httpErrorsMapToExpectedPOSIXCodes() {
  #expect(RemoteError.http(401).errno == EACCES)
  #expect(RemoteError.http(404).errno == ENOENT)
  #expect(RemoteError.http(409).errno == EEXIST)
  #expect(RemoteError.http(507).errno == ENOSPC)
  #expect(ChinaWebSupport.mapBusiness(code: 9008, message: nil) == .unauthorized)
  #expect(ChinaWebSupport.mapBusiness(code: 507, message: "空间不足") == .posix(ENOSPC))
  #expect(ChinaWebSupport.mapBusiness(code: 409, message: nil) == .posix(EEXIST))
}
