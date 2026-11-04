import Core
import Foundation
import Testing

@testable import LanzouDrive

private struct FakeReply: Sendable {
  let status: Int
  let body: Data
  let headers: [String: String]
  let url: URL?

  init(
    status: Int = 200, text: String = "", headers: [String: String] = [:], url: URL? = nil
  ) {
    self.status = status
    body = Data(text.utf8)
    self.headers = headers
    self.url = url
  }

  init(status: Int = 200, data: Data, headers: [String: String] = [:], url: URL? = nil) {
    self.status = status
    body = data
    self.headers = headers
    self.url = url
  }
}

private actor FakeHTTP: HTTPTransport {
  typealias Handler = @Sendable (URLRequest) throws -> FakeReply

  let handler: Handler
  private var sentRequests: [URLRequest] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    sentRequests.append(request)
    let reply = try handler(request)
    return HTTPResponse(
      status: reply.status, headers: reply.headers, body: reply.body, url: reply.url)
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    sentRequests.append(request)
    let reply = try handler(request)
    let response = HTTPResponse(
      status: reply.status, headers: reply.headers, body: reply.body, url: reply.url)
    return HTTPStreamResponse(
      response: response,
      body: AsyncThrowingStream { continuation in
        if !reply.body.isEmpty { continuation.yield(reply.body) }
        continuation.finish()
      })
  }

  func requests() -> [URLRequest] {
    sentRequests
  }
}

private func configuration(
  _ authentication: LanzouAuthentication
) throws -> LanzouConfiguration {
  try LanzouConfiguration(
    authentication: authentication,
    accountBaseURL: URL(string: "https://pc.example")!,
    shareBaseURL: URL(string: "https://share.example")!)
}

private func json(_ object: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: object)
}

private func form(_ request: URLRequest) -> [String: String] {
  guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else {
    return [:]
  }
  return text.split(separator: "&").reduce(into: [:]) { result, item in
    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard pair.count == 2 else { return }
    result[String(pair[0]).removingPercentEncoding ?? String(pair[0])] =
      String(pair[1]).removingPercentEncoding ?? String(pair[1])
  }
}

private func accountReply(_ request: URLRequest) -> FakeReply? {
  if request.url?.path == "/mydisk.php" {
    return FakeReply(
      text:
        #"<script>uid='user'; var vei='vei-value'; data : {'vei':'vei-value'};</script>"#)
  }
  guard request.url?.path == "/doupload.php" else { return nil }
  let fields = form(request)
  if fields["task"] == "47" {
    return FakeReply(
      data: json([
        "zt": 1,
        "text": [["name": "文件夹", "fol_id": "dir-id", "time": "2026-11-01"]],
      ]))
  }
  switch fields["pg"] {
  case "1":
    return FakeReply(
      data: json([
        "zt": 1,
        "text": [
          ["id": "file-1", "name_all": "一.txt", "size": "1 KB", "time": "2026-11-02"],
          ["id": "file-2", "name_all": "二.txt", "size": "2 KB", "time": "2026-11-02"],
        ],
      ]))
  case "2":
    return FakeReply(
      data: json([
        "zt": 1,
        "text": [["id": "file-3", "name_all": "三.txt", "size": "3 KB", "time": "2026-11-03"]],
      ]))
  default:
    return FakeReply(data: json(["zt": 1, "text": [Any]()]))
  }
}

private func shareSettingsPage(passwordRequired: Bool = false) -> String {
  let password = passwordRequired ? #"<div id="passwddiv"></div>"# : ""
  return """
    <html><title>文件.bin - 蓝奏云</title>
    <div class="fileinfo"></div>\(password)
    <span>大小 100 B</span>
    <iframe src="/inner"></iframe></html>
    """
}

private func shareDownloadReply(_ request: URLRequest) -> FakeReply? {
  switch (request.url?.host, request.url?.path) {
  case ("share.example", "/share"):
    return FakeReply(text: shareSettingsPage())
  case ("share.example", "/inner"):
    return FakeReply(
      text: """
        <script>
        url: '/ajaxm.php?file=123';
        data : '{"action":"downprocess","sign":"fake-sign"}';
        </script>
        """)
  case ("share.example", "/ajaxm.php"):
    return FakeReply(
      data: json([
        "zt": 1, "dom": "https://download.example", "url": "object", "inf": "文件.bin",
      ]))
  case ("download.example", "/file/object"):
    return FakeReply(
      status: 206, data: Data([4, 5, 6]),
      headers: [
        "Content-Range": "bytes 10-19/100"
      ])
  default:
    return nil
  }
}

@Test func accountPaginationAndLoginExpirationAreDetected() async throws {
  let http = FakeHTTP { request in
    try #require(accountReply(request))
  }
  let provider = LanzouProvider(
    configuration: try configuration(.accountCookie("phpdisk_info=fake")), transport: http)
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.map(\.name) == ["文件夹", "一.txt", "二.txt", "三.txt"])
  #expect(items.map(\.size) == [0, 1_024, 2_048, 3_072])

  let requests = await http.requests()
  let pageQueries = requests.compactMap {
    URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)
  }.compactMap { components in
    components.queryItems?.first(where: { $0.name == "uid" })?.value
  }
  #expect(pageQueries == ["user", "user", "user", "user"])
  #expect(
    requests.filter { $0.url?.path == "/doupload.php" }.map(form).map { $0["task"] } == [
      "47", "5", "5", "5",
    ])

  let expiredHTTP = FakeHTTP { request in
    if request.url?.path == "/mydisk.php" {
      return FakeReply(
        text: #"<script>uid='user'; var vei='vei';</script>"#)
    }
    return FakeReply(data: json(["zt": 9, "info": "登录失效"]))
  }
  let expired = LanzouProvider(
    configuration: try configuration(.accountCookie("phpdisk_info=fake")), transport: expiredHTTP)
  try await expired.connect()
  await #expect(throws: LanzouError.authenticationExpired) {
    try await expired.list(RemotePath("/"))
  }
}

@Test func shareFolderPaginationAndPasswordModelWork() async throws {
  let folderPage = """
    <html><div id="infos"></div>
    <a class="folderlink" href="/subfolder">子目录</a>
    <script>data : '{"task":"5"}'</script></html>
    """
  let http = FakeHTTP { request in
    if request.url?.path == "/folder" {
      return FakeReply(text: folderPage)
    }
    if request.url?.path == "/filemoreajax.php" {
      let page = form(request)["pg"]
      if page == "1" {
        return FakeReply(
          data: json([
            "zt": 1,
            "text": [["id": "f1", "name_all": "a.txt", "size": "1 K", "time": "2026-11-01"]],
          ]))
      }
      if page == "2" {
        return FakeReply(
          data: json([
            "zt": 1,
            "text": [["id": "f2", "name_all": "b.txt", "size": "2 K", "time": "2026-11-02"]],
          ]))
      }
      return FakeReply(data: json(["zt": 1, "text": [Any]()]))
    }
    throw LanzouError.invalidResponse
  }
  let provider = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/folder")!, password: nil)),
    transport: http)
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.map(\.name) == ["子目录", "a.txt", "b.txt"])
  #expect(items.first?.isDirectory == true)
  #expect(
    await http.requests().filter {
      $0.url?.path == "/filemoreajax.php"
    }.map { form($0)["pg"] } == ["1", "2", "3"])

  let protectedHTTP = FakeHTTP { _ in
    FakeReply(text: shareSettingsPage(passwordRequired: true))
  }
  let protected = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/protected")!, password: nil)),
    transport: protectedHTTP)
  await #expect(throws: LanzouError.passwordRequired) {
    try await protected.connect()
  }
}

@Test func rangeRequestCarriesHeaderAndRejectsFullResponse() async throws {
  let http = FakeHTTP { request in
    try #require(shareDownloadReply(request))
  }
  let provider = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/share")!, password: nil)), transport: http)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  var body = Data()
  for try await chunk in try await provider.read(RemotePath("/文件.bin"), range: 10..<20) {
    body.append(chunk)
  }
  #expect(body == Data([4, 5, 6]))
  let download = try #require(await http.requests().last { $0.url?.host == "download.example" })
  #expect(download.value(forHTTPHeaderField: "Range") == "bytes=10-19")
  #expect(download.value(forHTTPHeaderField: "Cookie")?.contains("down_ip=1") == true)
  #expect(
    LanzouSession.validContentRange("bytes 10-19/100", for: 10..<20, expectedSize: 100))
  #expect(
    !LanzouSession.validContentRange("bytes 10-19/999", for: 10..<20, expectedSize: 100))

  let unsupportedHTTP = FakeHTTP { request in
    if request.url?.host == "download.example" {
      return FakeReply(status: 200, data: Data([1, 2, 3]))
    }
    return try #require(shareDownloadReply(request))
  }
  let unsupported = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/share")!, password: nil)),
    transport: unsupportedHTTP)
  try await unsupported.connect()
  _ = try await unsupported.list(RemotePath("/"))
  await #expect(throws: LanzouError.rangeUnsupported) {
    try await unsupported.read(RemotePath("/文件.bin"), range: 0..<1)
  }
  #expect(
    unsupported.capabilities.supportsRangeRead
      && !unsupported.capabilities.canWrite
      && !unsupported.capabilities.canDelete)
}

@Test func businessAndHTTPErrorsStayDistinct() async throws {
  let notFoundHTTP = FakeHTTP { _ in FakeReply(text: "来晚啦...文件取消分享了") }
  let notFound = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/missing")!, password: nil)),
    transport: notFoundHTTP)
  await #expect(throws: LanzouError.notFound) {
    try await notFound.connect()
  }

  let limitedHTTP = FakeHTTP { request in
    if request.url?.path == "/mydisk.php" {
      return FakeReply(text: #"<script>uid='u'; var vei='v';</script>"#)
    }
    return FakeReply(status: 429)
  }
  let limited = LanzouProvider(
    configuration: try configuration(.accountCookie("phpdisk_info=fake")), transport: limitedHTTP)
  try await limited.connect()
  await #expect(throws: LanzouError.rateLimited) {
    try await limited.list(RemotePath("/"))
  }
  #expect(LanzouError.http(416).posixCode == EINVAL)
  #expect(LanzouError.http(409).posixCode == EEXIST)
  #expect(LanzouError.authenticationExpired.remoteError == RemoteError.unauthorized)
}

@Test func wrongPasswordAndReadOnlyWritesFailWithoutUpload() async throws {
  let wrongPasswordPage = """
    <html><title>文件.bin - 蓝奏云</title><div id="passwddiv"></div>
    <script>url:'/ajaxfile.php?file=1'; data : '{"action":"downprocess"}';</script>
    <span>大小 1 K</span></html>
    """
  let http = FakeHTTP { request in
    if request.url?.path == "/protected" {
      return FakeReply(text: wrongPasswordPage)
    }
    if request.url?.path == "/ajaxfile.php" {
      return FakeReply(data: json(["zt": 4, "inf": "密码错误"]))
    }
    throw LanzouError.invalidResponse
  }
  let provider = LanzouProvider(
    configuration: try configuration(
      .share(url: URL(string: "https://share.example/protected")!, password: "wrong")),
    transport: http)
  try await provider.connect()
  await #expect(throws: LanzouError.invalidPassword) {
    try await provider.read(RemotePath("/文件.bin"), range: nil)
  }
  let passwordRequest = try #require(
    await http.requests().last {
      $0.url?.path == "/ajaxfile.php"
    })
  #expect(form(passwordRequest)["p"] == "wrong")
  let beforeWrite = await http.requests().count
  await #expect(throws: RemoteError.posix(EROFS)) {
    try await provider.write(RemotePath("/文件.bin"), from: URL(fileURLWithPath: "/tmp/nope"))
  }
  #expect(await http.requests().count == beforeWrite)
}
