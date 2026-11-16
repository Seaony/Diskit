import Core
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private actor BaiduAuditHTTP: HTTPTransport {
  let reply: @Sendable (URLRequest) throws -> HTTPResponse
  var requests: [URLRequest] = []
  init(_ reply: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.reply = reply }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try reply(request)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    let response = try await send(request)
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream {
        $0.yield(response.body)
        $0.finish()
      })
  }
}

private func baiduJSON(_ object: Any) throws -> HTTPResponse {
  HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
}

private func baiduQuery(_ request: URLRequest) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func baiduFields(_ request: URLRequest) -> [String: String] {
  let value = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  return Dictionary(
    uniqueKeysWithValues: value.split(separator: "&").map {
      let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (
        String(pair[0]).removingPercentEncoding!,
        pair.count == 2 ? String(pair[1]).removingPercentEncoding! : ""
      )
    })
}

private func baiduAuditProvider(
  _ http: any HTTPTransport, root: String = "/apps/Diskit",
  now: @escaping @Sendable () -> Date = { Date() }
) throws -> BaiduDriveProvider {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "a+b", refreshToken: "local", expiresAt: .distantFuture)),
    for: "local")
  let session = OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "local", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/auth")!,
      tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://test",
      scopes: []), secretKey: "local", secrets: secrets, transport: http)
  return BaiduDriveProvider(
    configuration: BaiduDriveConfiguration(rootPath: root, appID: "local"), session: session,
    transport: http, now: now)
}

private func baiduItem(path: String, id: Int = 42) -> [String: Any] {
  [
    "path": path, "fs_id": id, "server_filename": (path as NSString).lastPathComponent, "size": 3,
    "isdir": 0,
  ]
}

@Test func baiduStatReusesParentListBrieflyThenRefreshes() async throws {
  let id = Mutex(42)
  let clock = Mutex(Date(timeIntervalSince1970: 0))
  let http = BaiduAuditHTTP { request in
    guard request.url?.host == "pan.baidu.com" else { return HTTPResponse(status: 404) }
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    let query = baiduQuery(request)
    guard request.url?.path == "/rest/2.0/xpan/file", query["method"] == "list",
      query["dir"] == "/apps/Diskit/a+b"
    else { return HTTPResponse(status: 404) }
    #expect(request.url!.absoluteString.contains("a%2Bb"))
    #expect(request.url!.absoluteString.contains("access_token=a%2Bb"))
    let current = id.withLock { value in
      defer { value += 1 }
      return value
    }
    return try baiduJSON([
      "errno": 0, "list": [baiduItem(path: "/apps/Diskit/a+b/file", id: current)],
    ])
  }
  let provider = try baiduAuditProvider(http, now: { clock.withLock { $0 } })
  try await provider.connect()
  #expect(try await provider.stat(RemotePath("/a+b/file")).size == 3)
  #expect(try await provider.stat(RemotePath("/a+b/file")).size == 3)
  #expect(id.withLock { $0 } == 43)
  clock.withLock { $0 += BaiduDriveProvider.listingLifetime }
  #expect(try await provider.stat(RemotePath("/a+b/file")).size == 3)
  #expect(id.withLock { $0 } == 44)
  #expect(await http.requests.count == 3)
}

@Test(arguments: [false, true])
func baiduDownloadsUseFileIDAndRejectMismatchedMetadata(wrongID: Bool) async throws {
  let http = BaiduAuditHTTP { request in
    if request.url?.host == "d.pcs.baidu.com", request.url?.path == "/download" {
      #expect(baiduQuery(request)["access_token"] == "a+b")
      #expect(request.url!.absoluteString.contains("access_token=a%2Bb"))
      return HTTPResponse(status: 200, body: Data([1, 2, 3]))
    }
    guard request.url?.host == "pan.baidu.com" else { return HTTPResponse(status: 404) }
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    let query = baiduQuery(request)
    if request.url?.path == "/rest/2.0/xpan/file", query["method"] == "list" {
      return try baiduJSON(["errno": 0, "list": [baiduItem(path: "/apps/Diskit/file")]])
    }
    guard request.url?.path == "/rest/2.0/xpan/multimedia", query["method"] == "filemetas",
      query["fsids"] == "[42]", query["dlink"] == "1"
    else { return HTTPResponse(status: 404) }
    var item = baiduItem(path: "/apps/Diskit/file", id: wrongID ? 99 : 42)
    item["dlink"] = "https://d.pcs.baidu.com/download"
    return try baiduJSON(["errno": 0, "list": [item]])
  }
  let provider = try baiduAuditProvider(http)
  try await provider.connect()
  if wrongID {
    await #expect(throws: RemoteError.protocolError) {
      _ = try await provider.read(RemotePath("/file"), range: nil)
    }
    #expect(await http.requests.count == 3)
  } else {
    var result = Data()
    for try await bytes in try await provider.read(RemotePath("/file"), range: nil) {
      result.append(bytes)
    }
    #expect(result == Data([1, 2, 3]))
  }
}

@Test(arguments: [0, 1, 2, 3, 4])
func baiduUploadUsesOfficialWireContractAndValidatesParts(mode: Int) async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("abc".utf8).write(to: file)
  let digest = "900150983cd24fb0d6963f7d28e17f72"
  let http = BaiduAuditHTTP { request in
    let query = baiduQuery(request)
    #expect(query["access_token"] == "a+b")
    if request.url?.host == "d.pcs.baidu.com", request.url?.path == "/rest/2.0/pcs/superfile2" {
      #expect(request.httpMethod == "POST")
      #expect(query["method"] == "upload" && query["type"] == "tmpfile")
      #expect(
        query["path"] == "/apps/Diskit/a+b" && query["uploadid"] == "upload"
          && query["partseq"] == "0")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("abc"))
      return try baiduJSON(["errno": 0, "md5": mode == 4 ? "bad-digest" : digest])
    }
    guard request.url?.host == "pan.baidu.com" else { return HTTPResponse(status: 404) }
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    guard request.url?.path == "/rest/2.0/xpan/file" else { return HTTPResponse(status: 404) }
    if query["method"] == "list" { return try baiduJSON(["errno": 0, "list": []]) }
    let fields = baiduFields(request)
    #expect(request.httpMethod == "POST")
    #expect(fields["method"] == nil && fields["access_token"] == nil)
    #expect(fields["path"] == "/apps/Diskit/a+b" && fields["rtype"] == "0")
    #expect(fields["block_list"] == "[\"\(digest)\"]")
    if query["method"] == "precreate" {
      return try baiduJSON([
        "errno": 0, "uploadid": "upload", "return_type": mode == 2 ? 2 : 1,
        "block_list": mode == 1 ? [] : mode == 3 ? [2] : [0],
      ])
    }
    guard query["method"] == "create" else { return HTTPResponse(status: 404) }
    return try baiduJSON(["errno": 0, "fs_id": 42])
  }
  let provider = try baiduAuditProvider(http)
  try await provider.connect()
  if mode >= 3 {
    await #expect(throws: RemoteError.protocolError) {
      try await provider.write(RemotePath("/a+b"), from: file)
    }
  } else {
    try await provider.write(RemotePath("/a+b"), from: file)
  }
  let requests = await http.requests
  let uploads = requests.filter { $0.url?.host == "d.pcs.baidu.com" }
  #expect(uploads.count == (mode == 0 || mode == 4 ? 1 : 0))
  #expect(!requests.contains { baiduQuery($0)["method"] == "locateupload" })
  #expect(requests.filter { baiduQuery($0)["method"] == "create" }.count == (mode < 2 ? 1 : 0))
}

@Test func baiduRateLimitAndDuplicatePathNeverTriggerMutation() async throws {
  for code in [31034, -8, 31190] {
    let http = BaiduAuditHTTP { request in
      guard request.url?.host == "pan.baidu.com" else { return HTTPResponse(status: 404) }
      if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
      #expect(request.httpMethod == "GET")
      return HTTPResponse(
        status: 200, headers: ["Retry-After": "0"],
        body: try JSONSerialization.data(withJSONObject: ["errno": code]))
    }
    let provider = try baiduAuditProvider(http)
    try await provider.connect()
    await #expect(
      throws: code == 31034 ? RemoteError.rateLimited : .posix(code == 31190 ? ENOSPC : EEXIST)
    ) {
      try await provider.makeDirectory(RemotePath("/new"))
    }
    // 31034 是限流，按退避重试满 3 次
    #expect(await http.requests.count == (code == 31034 ? 4 : 2))
  }
}

@Test func baiduRateLimitedListingRetriesThenSucceeds() async throws {
  let calls = Mutex(0)
  let http = BaiduAuditHTTP { request in
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    let first = calls.withLock {
      $0 += 1
      return $0 == 1
    }
    guard !first else {
      return HTTPResponse(
        status: 200, headers: ["Retry-After": "0"],
        body: try JSONSerialization.data(withJSONObject: ["errno": 31034]))
    }
    return try baiduJSON(["errno": 0, "list": [baiduItem(path: "/apps/Diskit/file")]])
  }
  let provider = try baiduAuditProvider(http)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).map(\.path.value) == ["/file"])
  #expect(calls.withLock { $0 } == 2)
}

@Test func baiduReadsReuseListingAndDownloadLinkAndRefreshExpiredLink() async throws {
  let filemetas = Mutex(0)
  let downloads = Mutex(0)
  let clock = Mutex(Date(timeIntervalSince1970: 0))
  let http = BaiduAuditHTTP { request in
    if request.url?.host == "d.pcs.baidu.com" {
      let count = downloads.withLock {
        $0 += 1
        return $0
      }
      // 第 3 次下载模拟地址过期
      if count == 3 { return HTTPResponse(status: 403) }
      #expect(request.url?.path == "/download\(filemetas.withLock { $0 })")
      return HTTPResponse(status: 206, body: Data([1]))
    }
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    let query = baiduQuery(request)
    if query["method"] == "list" {
      return try baiduJSON(["errno": 0, "list": [baiduItem(path: "/apps/Diskit/file")]])
    }
    let count = filemetas.withLock {
      $0 += 1
      return $0
    }
    var item = baiduItem(path: "/apps/Diskit/file")
    item["dlink"] = "https://d.pcs.baidu.com/download\(count)"
    return try baiduJSON(["errno": 0, "list": [item]])
  }
  let provider = try baiduAuditProvider(http, now: { clock.withLock { $0 } })
  try await provider.connect()
  for _ in 0..<2 {
    _ = try await provider.stat(RemotePath("/file"))
    _ = try await provider.read(RemotePath("/file"), range: 0..<1)
  }
  #expect(filemetas.withLock { $0 } == 1)
  _ = try await provider.read(RemotePath("/file"), range: 0..<1)
  #expect(filemetas.withLock { $0 } == 2)
  #expect(downloads.withLock { $0 } == 4)
  let lists = await http.requests.filter { baiduQuery($0)["method"] == "list" }.count
  #expect(lists == 1)
  clock.withLock { $0 += BaiduDriveProvider.downloadLinkLifetime }
  _ = try await provider.read(RemotePath("/file"), range: 0..<1)
  #expect(filemetas.withLock { $0 } == 3)
}

@Test func baiduMutationDropsCachedListing() async throws {
  let lists = Mutex(0)
  let http = BaiduAuditHTTP { request in
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    let query = baiduQuery(request)
    if query["method"] == "list" {
      lists.withLock { $0 += 1 }
      return try baiduJSON(["errno": 0, "list": [baiduItem(path: "/apps/Diskit/file")]])
    }
    return try baiduJSON(["errno": 0, "info": [["errno": 0]]])
  }
  let provider = try baiduAuditProvider(http)
  try await provider.connect()
  _ = try await provider.stat(RemotePath("/file"))
  try await provider.remove(RemotePath("/file"), recursive: false)
  #expect(lists.withLock { $0 } == 1)
  _ = try await provider.stat(RemotePath("/file"))
  #expect(lists.withLock { $0 } == 2)
}

@Test func baiduMalformedListingCannotAuthorizeCreatingAnExistingPath() async throws {
  let http = BaiduAuditHTTP { request in
    guard request.url?.host == "pan.baidu.com" else { return HTTPResponse(status: 404) }
    if request.url?.path == "/rest/2.0/xpan/nas" { return try baiduJSON(["errno": 0]) }
    #expect(request.httpMethod == "GET")
    return try baiduJSON(["errno": 0])
  }
  let provider = try baiduAuditProvider(http)
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.makeDirectory(RemotePath("/existing"))
  }
  #expect(await http.requests.count == 2)
}
