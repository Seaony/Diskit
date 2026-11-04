import Core
import Foundation
import Synchronization
import Testing

@testable import TianyiDrive

private final class TestSecrets: SecretStore, Sendable {
  private let values = Mutex<[String: Data]>([:])

  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

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

@Test func authenticationFailureInvalidatesStoredCookieSession() async throws {
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
      #expect(try secrets.read("tianyi.test") == nil)
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

@Test func familySessionKeyFailureInvalidatesWholeLogin() async throws {
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
  #expect(try secrets.read("tianyi.test") == nil)
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
