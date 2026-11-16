@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import TianyiDrive

private typealias TestSecrets = TestSecretStore

private actor FakeHTTP: HTTPTransport {
  typealias Reply = @Sendable (URLRequest) async throws -> HTTPResponse
  typealias StreamReply = @Sendable (URLRequest) async throws -> HTTPStreamResponse

  private let reply: Reply
  private let streamReply: StreamReply?
  private(set) var requests: [URLRequest] = []

  init(reply: @escaping Reply, streamReply: StreamReply? = nil) {
    self.reply = reply
    self.streamReply = streamReply
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try await reply(request)
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.append(request)
    if let streamReply { return try await streamReply(request) }
    let response = try await reply(request)
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream { continuation in
        if !response.body.isEmpty { continuation.yield(response.body) }
        continuation.finish()
      })
  }
}

private let personalConfiguration = TianyiConfiguration(scope: .personal, pageSize: 2)
private let familyConfiguration = TianyiConfiguration(
  scope: .family(familyID: "family-1"), pageSize: 2)

private func json(
  _ object: [String: Any], status: Int = 200, url: URL? = nil,
  headers: [String: String] = [:]
) -> HTTPResponse {
  HTTPResponse(
    status: status, headers: headers,
    body: try! JSONSerialization.data(withJSONObject: object), url: url)
}

private func sessionJSON(
  accessToken: String = "access", loginName: String = "天翼用户"
) -> HTTPResponse {
  json([
    "res_code": 0,
    "accessToken": accessToken,
    "refreshToken": "refresh",
    "sessionKey": "session-key",
    "sessionSecret": "secret-0123456789",
    "familySessionKey": "family-session-key",
    "familySessionSecret": "family-secret-0123456",
    "loginName": loginName,
  ])
}

private func capacity() -> HTTPResponse {
  json([
    "account": "user-1",
    "cloudCapacityInfo": ["totalSize": 1_000, "usedSize": 100],
    "familyCapacityInfo": ["totalSize": 2_000, "usedSize": 300],
  ])
}

private func storedSession(
  token: String = "access", includeFamily: Bool = true
) throws -> Data {
  let jar = try TianyiCookieJar(header: "SSON=cookie", domain: "cloud.189.cn")
  return try JSONEncoder().encode(
    StoredTianyiSession(
      accessToken: token, refreshToken: "refresh",
      personalCredentials: .init(
        sessionKey: "session-key", sessionSecret: "secret-0123456789"),
      familyCredentials:
        includeFamily
        ? .init(sessionKey: "family-session-key", sessionSecret: "family-secret-0123456")
        : nil,
      loginName: "天翼用户", cookies: jar))
}

private func session(
  _ http: FakeHTTP, key: String = "tianyi.test", token: String = "access",
  configuration: TianyiConfiguration = personalConfiguration, includeFamily: Bool = true
) throws -> (TianyiSession, TestSecrets) {
  let secrets = TestSecrets()
  try secrets.write(
    try storedSession(token: token, includeFamily: includeFamily), for: key)
  return (
    TianyiSession(
      secretKey: key, secrets: secrets, configuration: configuration, transport: http),
    secrets
  )
}

private func node(
  _ id: String, _ name: String, folder: Bool = false, size: Int64 = 12
) -> [String: Any] {
  [
    "id": id, "name": name, "size": size,
    "lastOpTime": "2026-01-02 03:04:05",
  ]
}

private func listPage(folders: [[String: Any]], files: [[String: Any]]) -> HTTPResponse {
  json([
    "fileListAO": [
      "count": folders.count + files.count,
      "folderList": folders,
      "fileList": files,
    ]
  ])
}

private func localFile(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try data.write(to: url)
  return url
}

private func form(_ request: URLRequest) -> [String: String] {
  let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  let items = URLComponents(string: "?" + text)?.queryItems ?? []
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Test func cookieLoginExchangesSessionAndRestrictsDomains() async throws {
  let finalURL = URL(string: "https://m.cloud.189.cn/login/complete?code=ok")!
  let http = FakeHTTP { request in
    switch request.url?.path {
    case "/api/portal/unifyLoginForPC.action":
      return HTTPResponse(
        status: 200,
        headers: ["Set-Cookie": "SSON_REFRESH=new; Domain=cloud.189.cn; Path=/; Secure"],
        url: finalURL)
    case "/login/complete":
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("SSON=cookie") == true)
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("SSON_REFRESH=new") == true)
      return HTTPResponse(status: 200, url: finalURL)
    case "/getSessionForPC.action":
      return sessionJSON()
    case "/portal/getUserSizeInfo.action":
      return capacity()
    default:
      Issue.record("未预期请求 \(request.url?.absoluteString ?? "")")
      throw RemoteError.protocolError
    }
  }
  let secrets = TestSecrets()
  let session = TianyiSession(
    secretKey: "cookie", secrets: secrets, configuration: personalConfiguration, transport: http)
  let account = try await session.login(cookie: "SSON=cookie; locale=zh")
  #expect(account.displayName == "天翼用户")
  let saved = try #require(try secrets.read("cookie"))
  let state = try JSONDecoder().decode(StoredTianyiSession.self, from: saved)
  #expect(state.personalCredentials.sessionKey == "session-key")
  #expect(state.familyCredentials?.sessionKey == "family-session-key")
  #expect(
    state.cookies.header(
      for: URL(string: "https://api.cloud.189.cn/file")!, trustedDomain: "cloud.189.cn")
      != nil)
  #expect(
    state.cookies.header(
      for: URL(string: "https://example.com/")!, trustedDomain: "cloud.189.cn")
      == nil)
  #expect(
    state.cookies.header(
      for: URL(string: "http://cloud.189.cn/")!, trustedDomain: "cloud.189.cn")
      == nil)
}

@Test func listFollowsEveryPageAndSortsEntries() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    if request.url?.path == "/file/listFiles.action" {
      let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "pageNum" }?.value
      if page == "1" {
        return listPage(
          folders: [node("dir", "目录", folder: true)],
          files: [node("b", "b.txt")])
      }
      #expect(page == "2")
      return listPage(folders: [], files: [node("a", "a.txt")])
    }
    throw RemoteError.protocolError
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  let items = try await provider.list(try RemotePath("/"))
  #expect(Set(items.map(\.name)) == Set(["a.txt", "b.txt", "目录"]))
  let pages = await http.requests.filter { $0.url?.path == "/file/listFiles.action" }
  #expect(pages.count == 2)
}

@Test func authenticationFailureWithoutExplicitRejectionPreservesStoredCookieSession() async throws
{
  for storageConfiguration in [personalConfiguration, familyConfiguration] {
    for failure in [
      HTTPResponse(status: 401),
      HTTPResponse(status: 400, body: Data(#"{"errorCode":"InvalidSessionKey"}"#.utf8)),
    ] {
      let http = FakeHTTP { request in
        let path = request.url?.path ?? ""
        if path == "/portal/getUserSizeInfo.action" { return failure }
        return HTTPResponse(status: 401)
      }
      let (session, secrets) = try session(http, configuration: storageConfiguration)
      let provider = TianyiProvider(session: session)
      await #expect(throws: RemoteError.unauthorized) { try await provider.connect() }
      #expect(try secrets.read("tianyi.test") != nil)
      #expect(try await session.hasLogin())
    }
  }
}

@Test(arguments: ["http", "https"])
func rangeReadUsesShortLivedURLAndValidatesContentRange(_ scheme: String) async throws {
  let downloadURL = URL(string: "https://download.189.cn/file?sig=one&part=two")!
  let http = FakeHTTP(
    reply: { request in
      if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
      if request.url?.path == "/file/listFiles.action" {
        return listPage(folders: [], files: [node("f", "movie.bin", size: 100)])
      }
      if request.url?.path == "/file/getFileDownloadUrl.action" {
        return json([
          "fileDownloadUrl": "\(scheme)://download.189.cn/file?sig=one&amp;part=two"
        ])
      }
      throw RemoteError.protocolError
    },
    streamReply: { request in
      #expect(request.url == downloadURL)
      #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      return HTTPStreamResponse(
        response: HTTPResponse(
          status: 206, headers: ["Content-Range": "bytes 10-19/100"]),
        body: AsyncThrowingStream { continuation in
          continuation.yield(Data(repeating: 7, count: 10))
          continuation.finish()
        })
    })
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  var data = Data()
  for try await chunk in try await provider.read(
    RemotePath("/movie.bin"), range: 10..<20)
  {
    data.append(chunk)
  }
  #expect(data == Data(repeating: 7, count: 10))
  #expect(
    TianyiProvider.validContentRange(
      "bytes 10-19/100", requested: 10..<20, size: 100))
  #expect(
    !TianyiProvider.validContentRange(
      "bytes 0-9/100", requested: 10..<20, size: 100))
}

@Test func httpAndServiceErrorsMapToPOSIXAndHTTP() {
  #expect(
    TianyiHTTP.map(
      status: 400, body: Data(#"{"res_message":"FileAlreadyExists"}"#.utf8))
      == .posix(EEXIST))
  #expect(
    TianyiHTTP.map(
      status: 400, body: Data(#"{"errorCode":"InvalidSessionKey"}"#.utf8))
      == .unauthorized)
  #expect(TianyiHTTP.map(status: 401, body: nil) == .unauthorized)
  #expect(TianyiHTTP.map(status: 404, body: nil) == .posix(ENOENT))
  #expect(TianyiHTTP.map(status: 429, body: nil) == .rateLimited)
  #expect(TianyiHTTP.map(status: 500, body: nil) == .http(500))
}

@Test func multipartUploadSendsExactPartsAndCommitsInOrder() async throws {
  let source = try localFile(Data((0..<10).map(UInt8.init)))
  defer { try? FileManager.default.removeItem(at: source) }
  let nextPart = Mutex(0)
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    if path == "/portal/getUserSizeInfo.action" { return capacity() }
    if path == "/file/listFiles.action" { return listPage(folders: [], files: []) }
    if path == "/person/initMultiUpload" {
      #expect(request.url?.query?.contains("params=") == true)
      #expect(!(request.value(forHTTPHeaderField: "Signature") ?? "").isEmpty)
      return json([
        "code": "SUCCESS",
        "data": ["uploadFileId": "upload-1", "fileDataExists": 0],
      ])
    }
    if path == "/person/getMultiUploadUrls" {
      let part = request.url?.query?.contains("params=") == true
      #expect(part)
      let number = nextPart.withLock { value in
        value += 1
        return value
      }
      return json([
        "code": "SUCCESS",
        "uploadUrls": [
          "partNumber_\(number)": [
            "requestURL": "https://upload.cloud.189.cn/part/\(number)",
            "requestHeader": "x-part=\(number)",
          ]
        ],
      ])
    }
    if path.hasPrefix("/part/") { return HTTPResponse(status: 200) }
    if path == "/person/commitMultiUploadFile" {
      return json(["code": "SUCCESS", "data": [:]])
    }
    Issue.record("未预期请求 \(path)")
    throw RemoteError.protocolError
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, uploadSliceSize: 4)
  try await provider.connect()
  try await provider.write(try RemotePath("/large.bin"), from: source)
  let requests = await http.requests
  let puts = requests.filter {
    $0.httpMethod == "PUT" && $0.url?.host == "upload.cloud.189.cn"
  }
  #expect(puts.map { $0.httpBody?.count } == [4, 4, 2])
  #expect(puts.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
  #expect(requests.last?.url?.path == "/person/commitMultiUploadFile")
}

@Test func uploadPlanCoversZeroExactAndRemainderBoundaries() throws {
  let path = try localFile(Data(repeating: 0x7a, count: 8))
  defer { try? FileManager.default.removeItem(at: path) }
  #expect(
    try TianyiUploadPlan.make(from: path, size: 0, requestedSliceSize: 4)
      .parts.map(\.length) == [0])
  #expect(
    try TianyiUploadPlan.make(from: path, size: 4, requestedSliceSize: 4)
      .parts.map(\.length) == [4])
  #expect(
    try TianyiUploadPlan.make(from: path, size: 8, requestedSliceSize: 4)
      .parts.map(\.length) == [4, 4])
  #expect(
    try TianyiUploadPlan.make(from: path, size: 7, requestedSliceSize: 4)
      .parts.map(\.length) == [4, 3])
}

@Test func existingNameFailsBeforeUploadTicket() async throws {
  let source = try localFile(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: source) }
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    if path == "/portal/getUserSizeInfo.action" { return capacity() }
    if path == "/file/listFiles.action" {
      return listPage(folders: [], files: [node("old", "same.txt")])
    }
    throw RemoteError.protocolError
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(try RemotePath("/same.txt"), from: source)
  }
  #expect(
    await http.requests.allSatisfy {
      !($0.url?.path.hasPrefix("/person/") ?? false)
    })
}

@Test func mutationsUseFolderBatchAndRenameEndpoints() async throws {
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    if path == "/portal/getUserSizeInfo.action" { return capacity() }
    if path == "/file/listFiles.action" {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems
      if query?.first(where: { $0.name == "folderId" })?.value == "dir"
        || query?.first(where: { $0.name == "pageNum" })?.value != "1"
      {
        return listPage(folders: [], files: [])
      }
      return listPage(
        folders: [node("dir", "dir", folder: true)],
        files: [node("f1", "a.txt")])
    }
    if path == "/file/createFolder.action" {
      return json(["res_code": 0])
    }
    if path == "/batch/createBatchTask.action" {
      let type = form(request)["type"]
      return json(["taskId": type == "MOVE" ? "move-task" : "delete-task"])
    }
    if path == "/batch/checkBatchTask.action" {
      return json(["taskId": form(request)["taskId"] ?? "", "taskStatus": 4])
    }
    if path == "/file/renameFile.action" {
      return json(["res_code": 0])
    }
    throw RemoteError.protocolError
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  try await provider.makeDirectory(try RemotePath("/new"))
  try await provider.move(try RemotePath("/a.txt"), to: try RemotePath("/dir/b.txt"))
  try await provider.remove(try RemotePath("/dir"), recursive: false)
  let requests = await http.requests
  #expect(requests.contains { $0.url?.path == "/file/createFolder.action" })
  #expect(requests.contains { $0.url?.path == "/file/renameFile.action" })
  #expect(
    requests.filter { $0.url?.path == "/batch/createBatchTask.action" }.count == 2)
  #expect(
    requests.filter { $0.url?.path == "/batch/checkBatchTask.action" }.count == 2)
}

@Test func familyUsesSeparateCredentialsRootPaginationAndRange() async throws {
  let downloadURL = URL(string: "https://download.189.cn/family/movie?sig=one")!
  let http = FakeHTTP(
    reply: { request in
      let path = request.url?.path ?? ""
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems
      if path == "/portal/getUserSizeInfo.action" {
        #expect(request.value(forHTTPHeaderField: "SessionKey") == "session-key")
        return capacity()
      }
      if path == "/family/file/listFiles.action" {
        #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
        #expect(query?.first { $0.name == "familyId" }?.value == "family-1")
        #expect(query?.first { $0.name == "orderBy" }?.value == "1")
        #expect(query?.first { $0.name == "recursive" } == nil)
        #expect(query?.first { $0.name == "folderId" }?.value == "")
        let page = query?.first { $0.name == "pageNum" }?.value
        if page == "1" {
          return listPage(
            folders: [node("dir", "家庭目录", folder: true)],
            files: [node("b", "b.txt")])
        }
        #expect(page == "2")
        return listPage(folders: [], files: [node("movie", "movie.bin", size: 100)])
      }
      if path == "/family/file/getFileDownloadUrl.action" {
        #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
        #expect(query?.first { $0.name == "familyId" }?.value == "family-1")
        #expect(query?.first { $0.name == "dt" } == nil)
        #expect(query?.first { $0.name == "flag" } == nil)
        return json([
          "fileDownloadUrl": "http://download.189.cn/family/movie?sig=one"
        ])
      }
      if path == "/family/manage/getFamilyList.action" {
        #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
        return json([
          "familyInfoResp": [
            ["familyId": 123, "remarkName": "我的家庭"]
          ]
        ])
      }
      throw RemoteError.protocolError
    },
    streamReply: { request in
      #expect(request.url == downloadURL)
      #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
      return HTTPStreamResponse(
        response: HTTPResponse(
          status: 206, headers: ["Content-Range": "bytes 10-19/100"]),
        body: AsyncThrowingStream { continuation in
          continuation.yield(Data(repeating: 9, count: 10))
          continuation.finish()
        })
    })
  let (session, _) = try session(http, configuration: familyConfiguration)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  let space = try await provider.spaceInfo()
  #expect(space == SpaceInfo(total: 2_000, used: 300))
  #expect(
    try await session.familySpaces() == [
      TianyiFamilySpace(familyID: "123", name: "我的家庭")
    ])
  let items = try await provider.list(try RemotePath("/"))
  #expect(Set(items.map(\.name)) == Set(["b.txt", "movie.bin", "家庭目录"]))
  var data = Data()
  for try await chunk in try await provider.read(
    RemotePath("/movie.bin"), range: 10..<20)
  {
    data.append(chunk)
  }
  #expect(data == Data(repeating: 9, count: 10))
}

@Test func familyMutationsUseFamilyParametersAndPersonalTaskCheck() async throws {
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems
    if path == "/portal/getUserSizeInfo.action" { return capacity() }
    if path == "/family/file/listFiles.action" {
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      let folderID = query?.first { $0.name == "folderId" }?.value
      if folderID == "dir" || query?.first(where: { $0.name == "pageNum" })?.value != "1" {
        return listPage(folders: [], files: [])
      }
      return listPage(
        folders: [node("dir", "dir", folder: true)],
        files: [node("f1", "a.txt")])
    }
    if path == "/family/file/createFolder.action" {
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      #expect(query?.first { $0.name == "familyId" }?.value == "family-1")
      #expect(query?.first { $0.name == "parentId" }?.value == "")
      #expect(query?.first { $0.name == "parentFolderId" } == nil)
      return json(["res_code": 0])
    }
    if path == "/batch/createBatchTask.action" {
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      #expect(form(request)["familyId"] == "family-1")
      let type = form(request)["type"]
      return json(["taskId": type == "MOVE" ? "move-task" : "delete-task"])
    }
    if path == "/batch/checkBatchTask.action" {
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "session-key")
      #expect(form(request)["familyId"] == nil)
      return json(["taskStatus": 4])
    }
    if path == "/family/file/renameFile.action" {
      #expect(request.httpMethod == "GET")
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      #expect(query?.first { $0.name == "familyId" }?.value == "family-1")
      return json(["res_code": 0])
    }
    throw RemoteError.protocolError
  }
  let (session, _) = try session(http, configuration: familyConfiguration)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  try await provider.makeDirectory(try RemotePath("/new"))
  try await provider.move(try RemotePath("/a.txt"), to: try RemotePath("/dir/b.txt"))
  try await provider.remove(try RemotePath("/dir"), recursive: false)
  let requests = await http.requests
  #expect(requests.contains { $0.url?.path == "/family/file/createFolder.action" })
  #expect(requests.contains { $0.url?.path == "/family/file/renameFile.action" })
  #expect(
    requests.filter { $0.url?.path == "/batch/createBatchTask.action" }.count == 2)
  #expect(
    requests.filter { $0.url?.path == "/batch/checkBatchTask.action" }.count == 2)
}

@Test func familyUploadUsesFamilyPrefixAndRejectsDuplicateName() async throws {
  let source = try localFile(Data((0..<10).map(UInt8.init)))
  defer { try? FileManager.default.removeItem(at: source) }
  let nextPart = Mutex(0)
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    if path == "/portal/getUserSizeInfo.action" { return capacity() }
    if path == "/family/file/listFiles.action" {
      return listPage(folders: [], files: [])
    }
    if path == "/family/initMultiUpload" {
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      let plan = try TianyiUploadPlan.make(
        from: source, size: 10, requestedSliceSize: 4)
      let expected = try TianyiCrypto.encryptedParameters(
        [
          "parentFolderId": "", "fileName": "large.bin", "fileSize": "10",
          "sliceSize": "4", "fileMd5": plan.fileMD5, "sliceMd5": plan.sliceMD5,
          "familyId": "family-1",
        ], sessionSecret: "family-secret-0123456")
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "params" }?.value == expected)
      return json([
        "code": "SUCCESS",
        "data": ["uploadFileId": "family-upload", "fileDataExists": 0],
      ])
    }
    if path == "/family/getMultiUploadUrls" {
      let number = nextPart.withLock { value in
        value += 1
        return value
      }
      let plan = try TianyiUploadPlan.make(
        from: source, size: 10, requestedSliceSize: 4)
      let expected = try TianyiCrypto.encryptedParameters(
        ["uploadFileId": "family-upload", "partInfo": plan.parts[number - 1].info],
        sessionSecret: "family-secret-0123456")
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "params" }?.value == expected)
      return json([
        "code": "SUCCESS",
        "uploadUrls": [
          "partNumber_\(number)": [
            "requestURL": "https://upload.cloud.189.cn/family/part/\(number)",
            "requestHeader": "x-family-part=\(number)",
          ]
        ],
      ])
    }
    if path.hasPrefix("/family/part/") { return HTTPResponse(status: 200) }
    if path == "/family/commitMultiUploadFile" {
      #expect(request.value(forHTTPHeaderField: "SessionKey") == "family-session-key")
      let expected = try TianyiCrypto.encryptedParameters(
        ["uploadFileId": "family-upload", "isLog": "0", "opertype": "1"],
        sessionSecret: "family-secret-0123456")
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "params" }?.value == expected)
      return json(["code": "SUCCESS", "data": [:]])
    }
    throw RemoteError.protocolError
  }
  let (liveSession, _) = try session(http, configuration: familyConfiguration)
  let provider = TianyiProvider(session: liveSession, uploadSliceSize: 4)
  try await provider.connect()
  try await provider.write(try RemotePath("/large.bin"), from: source)
  let puts = await http.requests.filter {
    $0.httpMethod == "PUT" && $0.url?.host == "upload.cloud.189.cn"
  }
  #expect(puts.map { $0.httpBody?.count } == [4, 4, 2])

  let duplicateHTTP = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    if request.url?.path == "/family/file/listFiles.action" {
      return listPage(folders: [], files: [node("old", "large.bin")])
    }
    throw RemoteError.protocolError
  }
  let (duplicateSession, _) = try session(
    duplicateHTTP, key: "family.duplicate", configuration: familyConfiguration)
  let duplicateProvider = TianyiProvider(session: duplicateSession)
  try await duplicateProvider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await duplicateProvider.write(try RemotePath("/large.bin"), from: source)
  }
  #expect(
    await duplicateHTTP.requests.allSatisfy {
      !($0.url?.path.hasPrefix("/family/initMultiUpload") ?? false)
    })
}

@Test func familyScopeRefusesToReusePersonalCredentials() async throws {
  let http = FakeHTTP { _ in
    Issue.record("家庭云缺少独立会话时不应发请求")
    throw RemoteError.protocolError
  }
  let (familySession, _) = try session(
    http, configuration: familyConfiguration, includeFamily: false)
  let provider = TianyiProvider(session: familySession)
  await #expect(throws: TianyiError.familyUnavailable) {
    try await provider.connect()
  }
  #expect(await http.requests.isEmpty)

  let personalHTTP = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    throw RemoteError.protocolError
  }
  let (personalSession, _) = try session(
    personalHTTP, key: "personal.no-family", includeFamily: false)
  let personalProvider = TianyiProvider(session: personalSession)
  try await personalProvider.connect()
}

@Test func familySessionKeyFailurePreservesRecoverableLogin() async throws {
  let http = FakeHTTP { request in
    switch request.url?.path {
    case "/portal/getUserSizeInfo.action":
      return capacity()
    case "/family/file/listFiles.action":
      return HTTPResponse(
        status: 400, body: Data(#"{"errorCode":"InvalidSessionKey"}"#.utf8))
    default:
      return HTTPResponse(status: 401)
    }
  }
  let (session, secrets) = try session(http, configuration: familyConfiguration)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  await #expect(throws: RemoteError.unauthorized) {
    try await provider.list(try RemotePath("/"))
  }
  #expect(try secrets.read("tianyi.test") != nil)
  #expect(try await session.hasLogin())
}

@Test func signedRequestsPreservePlusInQueryAndFormValues() async throws {
  let http = FakeHTTP { request in
    guard request.url?.path == "/file/createFolder.action" else { throw RemoteError.protocolError }
    let encodedQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      .percentEncodedQuery!
    #expect(encodedQuery.contains("folderName=a%2Bb"))
    let body = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(body == "folderName=a%2Bb")
    return json(["res_code": 0])
  }
  let (session, _) = try session(http)
  _ = try await session.api(
    path: "/file/createFolder.action", method: "POST",
    query: [URLQueryItem(name: "folderName", value: "a+b")], form: ["folderName": "a+b"])
}

@Test func partialPagesContinueUntilReportedCountIsComplete() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    guard request.url?.path == "/file/listFiles.action",
      let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "pageNum" })?.value,
      let page = Int(value), (1...3).contains(page)
    else { throw RemoteError.protocolError }
    return json([
      "fileListAO": [
        "count": 3, "folderList": [], "fileList": [node("id-\(page)", "file-\(page)")],
      ]
    ])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  let files = try await provider.list(RemotePath("/"))
  #expect(files.map(\.name) == ["file-1", "file-2", "file-3"])
  #expect(await http.requests.filter { $0.url?.path == "/file/listFiles.action" }.count == 3)
}

@Test func missingPageFailsInsteadOfReturningPartialDirectory() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    guard request.url?.path == "/file/listFiles.action" else { throw RemoteError.protocolError }
    let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "pageNum"
    }?.value
    return json([
      "fileListAO": ["count": 3, "folderList": [], "fileList": page == "1" ? [node("a", "a")] : []]
    ])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  await #expect(throws: TianyiError.invalidResponse) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test func pagesWithoutCountContinueUntilEmptyPage() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    guard request.url?.path == "/file/listFiles.action" else { throw RemoteError.protocolError }
    let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "pageNum"
    }?.value
    return json(["fileListAO": ["folderList": [], "fileList": page == "1" ? [node("a", "a")] : []]])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).map(\.name) == ["a"])
  #expect(await http.requests.filter { $0.url?.path == "/file/listFiles.action" }.count == 2)
}

@Test(arguments: [0, 429, 500, 401])
func tianyiTransientRestorationPreservesLogin(_ status: Int) async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return HTTPResponse(status: 401) }
    guard
      ["/getSessionForPC.action", "/api/portal/unifyLoginForPC.action"].contains(
        request.url?.path ?? "")
    else { throw RemoteError.protocolError }
    if status == 0 { throw URLError(.notConnectedToInternet) }
    return HTTPResponse(status: status, body: Data("{}".utf8))
  }
  let (session, secrets) = try session(http)
  let original = try secrets.read("tianyi.test")
  do {
    try await session.connect()
    Issue.record("恢复失败不应成功")
  } catch { if status != 401 { #expect((error as? RemoteError) != .unauthorized) } }
  #expect(try secrets.read("tianyi.test") == original)
  #expect(try await session.hasLogin())
}

@Test func tianyiExplicitInvalidGrantInvalidatesLogin() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return HTTPResponse(status: 401) }
    guard
      ["/getSessionForPC.action", "/api/portal/unifyLoginForPC.action"].contains(
        request.url?.path ?? "")
    else { throw RemoteError.protocolError }
    return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
  }
  let (session, secrets) = try session(http)
  await #expect(throws: RemoteError.unauthorized) { try await session.connect() }
  #expect(try secrets.read("tianyi.test") == nil)
  #expect(try await !session.hasLogin())
}

@Test func tianyiRestorationRecoversAfterServerFailure() async throws {
  let attempts = Mutex(0)
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" {
      return attempts.withLock { $0 } >= 2 ? capacity() : HTTPResponse(status: 401)
    }
    guard request.url?.path == "/getSessionForPC.action" else { throw RemoteError.protocolError }
    let number = attempts.withLock {
      $0 += 1
      return $0
    }
    return number == 1 ? HTTPResponse(status: 500) : sessionJSON(accessToken: "recovered")
  }
  let (session, secrets) = try session(http)
  do {
    try await session.connect()
    Issue.record("首次恢复应失败")
  } catch {}
  #expect(try await session.hasLogin())
  try await session.connect()
  let stored = try JSONDecoder().decode(
    StoredTianyiSession.self, from: #require(try secrets.read("tianyi.test")))
  #expect(stored.accessToken == "recovered")
  #expect(attempts.withLock { $0 } == 2)
}

@Test(arguments: [false, true])
func tianyiRetriesPersistingRecoveredSessionBeforeUsingIt(newSession: Bool) async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" {
      return request.value(forHTTPHeaderField: "SessionKey") == "new-key"
        ? capacity() : HTTPResponse(status: 401)
    }
    guard request.url?.path == "/getSessionForPC.action" else { throw RemoteError.protocolError }
    return json([
      "sessionKey": "new-key", "sessionSecret": "new-secret", "accessToken": "new-access",
      "refreshToken": "rotated",
    ])
  }
  let (session, secrets) = try session(http)
  secrets.failWrites.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { try await session.connect() }
  secrets.failWrites.withLock { $0 = false }
  let retrySession =
    newSession
    ? TianyiSession(
      secretKey: "tianyi.test", secrets: secrets, configuration: personalConfiguration,
      transport: http) : session
  try await retrySession.connect()
  let saved = try JSONDecoder().decode(
    StoredTianyiSession.self, from: #require(try secrets.read("tianyi.test")))
  #expect(saved.accessToken == "new-access" && saved.refreshToken == "rotated")
  #expect(await http.requests.filter { $0.url?.path == "/getSessionForPC.action" }.count == 1)
}

@Test func tianyiObservesCredentialsChangedOutsideTheSession() async throws {
  let http = FakeHTTP { _ in capacity() }
  let (session, secrets) = try session(http)
  try await session.connect()
  var saved = try JSONDecoder().decode(StoredTianyiSession.self, from: storedSession())
  saved.personalCredentials = .init(
    sessionKey: "replacement-key", sessionSecret: "replacement-secret")
  try secrets.write(JSONEncoder().encode(saved), for: "tianyi.test")
  _ = try await session.account()
  #expect(await http.requests.last?.value(forHTTPHeaderField: "SessionKey") == "replacement-key")
  try secrets.delete("tianyi.test")
  await #expect(throws: RemoteError.unauthorized) { _ = try await session.account() }
  #expect(await http.requests.count == 2)
}

@Test(arguments: [false, true])
func tianyiSeparateSessionsShareRestoration(separateSessions: Bool) async throws {
  let started = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let secondRequest = AsyncStream<Void>.makeStream()
  let requests = Mutex(0)
  let restores = Mutex(0)
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" {
      if request.value(forHTTPHeaderField: "SessionKey") == "new-key" { return capacity() }
      if requests.withLock({
        $0 += 1
        return $0
      }) == 2 {
        secondRequest.continuation.yield(())
        secondRequest.continuation.finish()
      }
      return HTTPResponse(status: 401)
    }
    guard request.url?.path == "/getSessionForPC.action" else { throw RemoteError.protocolError }
    if restores.withLock({
      $0 += 1
      return $0
    }) == 1 {
      started.continuation.yield(())
      started.continuation.finish()
      for await _ in release.stream { break }
    }
    return json([
      "sessionKey": "new-key", "sessionSecret": "new-secret", "accessToken": "new",
      "refreshToken": "rotated",
    ])
  }
  let (first, secrets) = try session(http)
  let second =
    separateSessions
    ? TianyiSession(
      secretKey: "tianyi.test", secrets: secrets, configuration: personalConfiguration,
      transport: http) : first
  let firstTask = Task { try await first.connect() }
  for await _ in started.stream { break }
  let secondTask = Task { try await second.connect() }
  for await _ in secondRequest.stream { break }
  release.continuation.yield(())
  release.continuation.finish()
  try await firstTask.value
  try await secondTask.value
  #expect(restores.withLock { $0 } == 1)
}

@Test func tianyiLoginValidatesBeforeReplacingSavedCredentials() async throws {
  let finalURL = URL(string: "https://m.cloud.189.cn/login/complete")!
  let http = FakeHTTP { request in
    switch request.url?.path {
    case "/api/portal/unifyLoginForPC.action": return HTTPResponse(status: 200, url: finalURL)
    case "/login/complete": return HTTPResponse(status: 200, url: finalURL)
    case "/getSessionForPC.action": return sessionJSON(accessToken: "unverified")
    case "/portal/getUserSizeInfo.action":
      return json(["cloudCapacityInfo": ["totalSize": 2, "usedSize": -1]])
    default: throw RemoteError.protocolError
    }
  }
  let (session, secrets) = try session(http)
  let saved = try secrets.read("tianyi.test")
  await #expect(throws: TianyiError.invalidResponse) {
    _ = try await session.login(cookie: "SSON=new-cookie")
  }
  #expect(try secrets.read("tianyi.test") == saved)
}

@Test func tianyiLoginSendsScopedCookieAndFollowsRedirectLocation() async throws {
  let http = FakeHTTP { request in
    if request.url?.path != "/portal/getUserSizeInfo.action" {
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("SSON=cookie") == true)
    }
    switch request.url?.path {
    case "/api/portal/unifyLoginForPC.action":
      return HTTPResponse(status: 302, headers: ["Location": "/login/complete"], url: request.url)
    case "/login/complete": return HTTPResponse(status: 200, url: request.url)
    case "/getSessionForPC.action": return sessionJSON()
    case "/portal/getUserSizeInfo.action":
      // 账号校验使用新会话签名，不需要 Cookie。
      return capacity()
    default: throw RemoteError.protocolError
    }
  }
  let secrets = TestSecrets()
  let session = TianyiSession(
    secretKey: "new", secrets: secrets, configuration: personalConfiguration, transport: http)
  _ = try await session.login(cookie: "SSON=cookie")
  #expect(try await session.hasLogin())
}

@Test(arguments: ["captcha_required", "risk_control", "需要验证码"])
func tianyiVerificationChallengeDoesNotInvalidateLogin(reason: String) async throws {
  let response = json(["errorCode": reason], status: 401)
  #expect(!TianyiHTTP.isAuthenticationFailure(response))
  #expect(!TianyiError.service(reason).requiresLogin)
  #expect(!TianyiError.familyUnavailable.requiresLogin)
  #expect(TianyiError.loginRequired.requiresLogin)
  let http = FakeHTTP { _ in response }
  let (session, secrets) = try session(http)
  let saved = try secrets.read("tianyi.test")
  await #expect(throws: TianyiError.service("需要在天翼云盘网页完成验证")) { _ = try await session.account() }
  #expect(try secrets.read("tianyi.test") == saved)
  #expect(await http.requests.count == 1)
}

@Test func tianyiTaskProgressExtendsIdleDeadline() async throws {
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(
    interval: .seconds(3),
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
  let calls = Mutex(0)
  let http = FakeHTTP { request in
    guard request.url?.path == "/batch/checkBatchTask.action" else {
      throw RemoteError.protocolError
    }
    let number = calls.withLock { $0 += 1; return $0 }
    clock.advance(by: .seconds(1))
    return json(["taskId": "task", "taskStatus": number < 5 ? 1 : 4, "process": number * 10])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.waitForTask(taskID: "task", type: "MOVE", deadline: deadline)
  #expect(calls.withLock { $0 } == 5)
}

@Test func tianyiRepeatedTaskProgressStillTimesOut() async throws {
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(
    interval: .seconds(3),
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
  let calls = Mutex(0)
  let waiting = TestEvent()
  let blocked = TestEvent()
  let http = FakeHTTP { _ in
    let number = calls.withLock { $0 += 1; return $0 }
    if number == 3 {
      waiting.signal()
      try await blocked.wait()
    }
    clock.advance(by: .seconds(1))
    return json(["taskId": "task", "taskStatus": 1, "process": 10, "successedCount": 1])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  let operation = Task {
    try await provider.waitForTask(taskID: "task", type: "MOVE", deadline: deadline)
  }
  try await waiting.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .milliseconds(2500))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await operation.value }
  #expect(calls.withLock { $0 } == 3)
}

@Test(arguments: [2, 4])
func tianyiCompletedTaskWithFailedItemsIsNotSuccess(state: Int) async throws {
  let http = FakeHTTP { _ in json(["taskStatus": state, "failedCount": 1, "successedCount": 2]) }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  await #expect(throws: RemoteError.posix(state == 2 ? EEXIST : EIO)) {
    try await provider.waitForTask(taskID: "task", type: "DELETE")
  }
}

@Test func tianyiRepeatedFileIdentityDoesNotProduceDuplicatePaths() async throws {
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    return listPage(folders: [], files: [node("same", "a"), node("same", "b")])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  await #expect(throws: TianyiError.invalidResponse) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test func tianyiDelayedListCannotRestoreDeletedEntryInCache() async throws {
  let waiting = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let calls = Mutex(0)
  let deleted = Mutex(false)
  let http = FakeHTTP { request in
    switch request.url?.path {
    case "/portal/getUserSizeInfo.action": return capacity()
    case "/file/listFiles.action":
      let number = calls.withLock {
        $0 += 1
        return $0
      }
      if number == 2 {
        waiting.continuation.yield(())
        waiting.continuation.finish()
        for await _ in release.stream { break }
        return listPage(folders: [], files: [node("file", "a")])
      }
      return listPage(folders: [], files: deleted.withLock { $0 } ? [] : [node("file", "a")])
    case "/batch/createBatchTask.action": return json(["taskId": "delete"])
    case "/batch/checkBatchTask.action":
      deleted.withLock { $0 = true }
      return json(["taskStatus": 4])
    default: throw RemoteError.protocolError
    }
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  let oldListing = Task { try await provider.list(RemotePath("/")) }
  for await _ in waiting.stream { break }
  try await provider.remove(RemotePath("/a"), recursive: false)
  release.continuation.yield(())
  release.continuation.finish()
  _ = try await oldListing.value
  await #expect(throws: RemoteError.posix(ENOENT)) { _ = try await provider.stat(RemotePath("/a")) }
}

private actor TianyiMoveHTTP: HTTPTransport {
  var files: [String: (parent: String, name: String)] = [
    "target": ("src", "a"), "source-other": ("src", "b"), "destination-other": ("dst", "a"),
  ]
  let failRename: Bool
  let failRollback: Bool
  init(failRename: Bool = false, failRollback: Bool = false) {
    self.failRename = failRename
    self.failRollback = failRollback
  }
  func location() -> String { files["target"].map { $0.parent + "/" + $0.name } ?? "missing" }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
    switch request.url?.path {
    case "/portal/getUserSizeInfo.action": return capacity()
    case "/file/listFiles.action":
      guard value("pageNum") == "1" else { return listPage(folders: [], files: []) }
      if value("folderId") == "-11" {
        return listPage(folders: [node("src", "src"), node("dst", "dst")], files: [])
      }
      return listPage(
        folders: [],
        files: files.filter { $0.value.parent == value("folderId") }.map {
          node($0.key, $0.value.name)
        })
    case "/file/renameFile.action":
      let id = value("fileId")
      let name = value("destFileName")
      guard var file = files[id] else { return HTTPResponse(status: 404) }
      if failRename, file.parent == "dst", name == "b" { return HTTPResponse(status: 500) }
      if files.contains(where: {
        $0.key != id && $0.value.parent == file.parent && $0.value.name == name
      }) {
        return HTTPResponse(status: 409)
      }
      file.name = name
      files[id] = file
      return json(["res_code": 0])
    case "/batch/createBatchTask.action":
      let fields = form(request)
      let destination = fields["targetFolderId"] ?? ""
      guard let taskData = fields["taskInfos"]?.data(using: .utf8),
        let infos = try JSONSerialization.jsonObject(with: taskData) as? [[String: Any]],
        let id = infos.first?["fileId"] as? String, var file = files[id]
      else { throw RemoteError.protocolError }
      if failRollback, destination == "src", file.parent == "dst" {
        return HTTPResponse(status: 503)
      }
      if files.contains(where: {
        $0.key != id && $0.value.parent == destination && $0.value.name == file.name
      }) {
        return HTTPResponse(status: 409)
      }
      file.parent = destination
      files[id] = file
      return json(["taskId": "move"])
    case "/batch/checkBatchTask.action": return json(["taskStatus": 4])
    default: throw RemoteError.protocolError
    }
  }
}

@Test func tianyiCrossDirectoryRenameAvoidsBothIntermediateNameConflicts() async throws {
  let http = TianyiMoveHTTP()
  let secrets = MemorySecretStore()
  try secrets.write(storedSession(), for: "move")
  let session = TianyiSession(
    secretKey: "move", secrets: secrets, configuration: personalConfiguration, transport: http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  try await provider.move(RemotePath("/src/a"), to: RemotePath("/dst/b"))
  #expect(await http.location() == "dst/b")
  #expect(try await provider.list(RemotePath("/src")).map(\.name) == ["b"])
  #expect(Set(try await provider.list(RemotePath("/dst")).map(\.name)) == Set(["a", "b"]))
}

@Test(arguments: [false, true])
func tianyiCrossDirectoryRenameFailureRestoresOrReportsLastKnownLocation(rollbackFails: Bool)
  async throws
{
  let http = TianyiMoveHTTP(failRename: true, failRollback: rollbackFails)
  let secrets = MemorySecretStore()
  try secrets.write(storedSession(), for: "move")
  let session = TianyiSession(
    secretKey: "move", secrets: secrets, configuration: personalConfiguration, transport: http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  if rollbackFails {
    do {
      try await provider.move(RemotePath("/src/a"), to: RemotePath("/dst/b"))
      Issue.record("恢复失败应明确报告")
    } catch let failure as TianyiMoveRecoveryFailure {
      #expect(failure.lastConfirmedPath.value.hasPrefix("/dst/.diskit-move-"))
      #expect(failure.original as? RemoteError == .http(500))
    }
    #expect(await http.location().hasPrefix("dst/.diskit-move-"))
  } else {
    await #expect(throws: RemoteError.http(500)) {
      try await provider.move(RemotePath("/src/a"), to: RemotePath("/dst/b"))
    }
    #expect(await http.location() == "src/a")
  }
}

@Test(arguments: ["negative-size", "missing-size", "invalid-name", "missing-id"])
func malformedTianyiEntryFailsWithoutReturningPartialDirectory(problem: String) async throws {
  var bad = node("bad", "bad")
  switch problem {
  case "negative-size": bad["size"] = -1
  case "missing-size": bad.removeValue(forKey: "size")
  case "invalid-name": bad["name"] = "nested/path"
  default: bad["id"] = ""
  }
  let badJSON = try JSONSerialization.data(withJSONObject: [
    "fileListAO": ["count": 2, "fileList": [node("ok", "ok"), bad], "folderList": []]
  ])
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" { return capacity() }
    return HTTPResponse(status: 200, body: badJSON)
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  await #expect(throws: TianyiError.invalidResponse) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test(arguments: [false, true])
func tianyiTenConcurrentRejectionsShareRestoration(separateSessions: Bool) async throws {
  let restored = Mutex(0)
  let oldRequests = Mutex(0)
  let rejected = TestEvent()
  let http = FakeHTTP { request in
    if request.url?.path == "/portal/getUserSizeInfo.action" {
      if request.value(forHTTPHeaderField: "SessionKey") == "new-key" { return capacity() }
      if oldRequests.withLock({ $0 += 1; return $0 }) == 10 { rejected.signal() }
      try await rejected.wait()
      return HTTPResponse(status: 401)
    }
    guard request.url?.path == "/getSessionForPC.action" else { throw RemoteError.protocolError }
    restored.withLock { $0 += 1 }
    return json([
      "sessionKey": "new-key", "sessionSecret": "new-secret", "accessToken": "new",
      "refreshToken": "rotated",
    ])
  }
  let (first, secrets) = try session(http)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<10 {
      let current =
        separateSessions
        ? TianyiSession(
          secretKey: "tianyi.test", secrets: secrets, configuration: personalConfiguration,
          transport: http) : first
      group.addTask { try await current.connect() }
    }
    try await group.waitForAll()
  }
  #expect(restored.withLock { $0 } == 1)
}

@Test func tianyiOverQuotaAccountStillConnects() async throws {
  let http = FakeHTTP { _ in
    json(["cloudCapacityInfo": ["totalSize": 1_000, "usedSize": 1_500]])
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  let space = try await provider.spaceInfo()
  #expect(space.total == 1_000)
  #expect(space.used == 1_500)
}

@Test(arguments: ["captcha_test.png", "验证码截图.png", "风控记录.txt", "invalidsessionkey.txt"])
func tianyiFileNamesDoNotLookLikeChallengeOrExpiredSession(name: String) async throws {
  let http = FakeHTTP { request in
    switch request.url?.path {
    case "/portal/getUserSizeInfo.action": return capacity()
    case "/file/listFiles.action":
      return json([
        "res_code": 0, "res_message": "成功",
        "fileListAO": ["count": 1, "folderList": [], "fileList": [node("f", name)]],
      ])
    default: throw RemoteError.protocolError
    }
  }
  let (session, secrets) = try session(http)
  let saved = try secrets.read("tianyi.test")
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).map(\.name) == [name])
  #expect(try secrets.read("tianyi.test") == saved)
  #expect(!(await http.requests).contains { $0.url?.path == "/getSessionForPC.action" })
}

@Test func tianyiChallengeInServiceFieldsOrNonJSONPageIsStillDetected() async throws {
  for response in [
    json(["res_code": 1, "res_message": "请输入验证码"]),
    HTTPResponse(status: 403, body: Data("<html>captcha required</html>".utf8)),
  ] {
    let http = FakeHTTP { _ in response }
    let (session, _) = try session(http)
    await #expect(throws: TianyiError.service("需要在天翼云盘网页完成验证")) {
      _ = try await session.account()
    }
  }
  #expect(
    TianyiHTTP.isAuthenticationFailure(json(["res_code": "InvalidSessionKey"], status: 400)))
  #expect(
    !TianyiHTTP.isAuthenticationFailure(
      json(["res_code": 0, "fileListAO": ["fileList": [node("f", "invalidsessionkey")]]])))
}

private actor DownloadLinkServer {
  var linkRequests = 0
  var rejectNextDownload = false
  var size: Int64 = 100

  func nextLink() -> Int {
    linkRequests += 1
    return linkRequests
  }

  func takeRejection() -> Bool {
    defer { rejectNextDownload = false }
    return rejectNextDownload
  }

  func rejectNext() { rejectNextDownload = true }
  func resize(_ value: Int64) { size = value }
}

@Test func tianyiReusesDownloadURLAndRefreshesItOnceWhenExpired() async throws {
  let server = DownloadLinkServer()
  let http = FakeHTTP(
    reply: { request in
      switch request.url?.path {
      case "/portal/getUserSizeInfo.action": return capacity()
      case "/file/listFiles.action":
        return listPage(folders: [], files: [node("f", "movie.bin", size: await server.size)])
      case "/file/getFileDownloadUrl.action":
        let number = await server.nextLink()
        return json(["fileDownloadUrl": "https://download.189.cn/file?sig=\(number)"])
      default: throw RemoteError.protocolError
      }
    },
    streamReply: { request in
      if await server.takeRejection() {
        return HTTPStreamResponse(
          response: HTTPResponse(status: 403), body: AsyncThrowingStream { $0.finish() })
      }
      let range = request.value(forHTTPHeaderField: "Range") ?? ""
      let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int64($0) }
      let size = await server.size
      return HTTPStreamResponse(
        response: HTTPResponse(
          status: 206, headers: ["Content-Range": "bytes \(bounds[0])-\(bounds[1])/\(size)"]),
        body: AsyncThrowingStream {
          $0.yield(Data(repeating: 1, count: Int(bounds[1] - bounds[0] + 1)))
          $0.finish()
        })
    })
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session)
  try await provider.connect()
  let path = try RemotePath("/movie.bin")
  func read(_ range: Range<Int64>) async throws -> Int {
    var count = 0
    for try await chunk in try await provider.read(path, range: range) { count += chunk.count }
    return count
  }
  #expect(try await read(0..<10) == 10)
  #expect(try await read(10..<20) == 10)
  #expect(await server.linkRequests == 1)

  await server.rejectNext()
  #expect(try await read(20..<30) == 10)
  #expect(await server.linkRequests == 2)
  let downloads = await http.requests.filter { $0.url?.host == "download.189.cn" }
  #expect(downloads.suffix(2).map { $0.url?.query } == ["sig=1", "sig=2"])

  // 文件大小变了说明内容换了，旧地址不再沿用
  await server.resize(200)
  _ = try await provider.list(RemotePath("/"))
  #expect(try await read(0..<10) == 10)
  #expect(await server.linkRequests == 3)
}

@Test func tianyiDuplicateNamesGetFinderStyleNamesAndMapBackToTheirIDs() async throws {
  let http = FakeHTTP { request in
    let path = request.url?.path ?? ""
    switch path {
    case "/portal/getUserSizeInfo.action": return capacity()
    case "/file/listFiles.action":
      guard request.url?.query?.contains("pageNum=1&") == true else {
        return listPage(folders: [], files: [])
      }
      return listPage(
        folders: [],
        files: [node("f2", "a.txt", size: 20), node("f1", "a.txt", size: 10)])
    case "/batch/createBatchTask.action": return json(["taskId": "task"])
    case "/batch/checkBatchTask.action": return json(["taskStatus": 4])
    case "/file/renameFile.action": return json(["res_code": 0])
    default: throw RemoteError.protocolError
    }
  }
  let (session, _) = try session(http)
  let provider = TianyiProvider(session: session, taskPollInterval: .zero)
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(Set(items.map(\.path.value)) == ["/a.txt", "/a (2).txt"])
  #expect(items.allSatisfy { $0.path.basename == $0.name })
  #expect(try await provider.stat(RemotePath("/a (2).txt")).size == 20)
  #expect(try await provider.stat(RemotePath("/a.txt")).size == 10)

  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/a (2).txt"))
  }

  try await provider.move(RemotePath("/a (2).txt"), to: RemotePath("/b.txt"))
  let rename = try #require(
    await http.requests.last { $0.url?.path == "/file/renameFile.action" })
  let query = URLComponents(url: rename.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  #expect(query.first { $0.name == "fileId" }?.value == "f2")
  #expect(query.first { $0.name == "destFileName" }?.value == "b.txt")

  try await provider.remove(RemotePath("/a (2).txt"), recursive: false)
  let delete = try #require(
    await http.requests.last { $0.url?.path == "/batch/createBatchTask.action" })
  let infos = try #require(form(delete)["taskInfos"]?.data(using: .utf8))
  let task = try #require(
    (try JSONSerialization.jsonObject(with: infos) as? [[String: Any]])?.first)
  #expect(task["fileId"] as? String == "f2")
  #expect(task["fileName"] as? String == "a.txt")
}
