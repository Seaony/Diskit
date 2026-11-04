import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import LanzouDrive

private func auditConfiguration(_ authentication: LanzouAuthentication) throws
  -> LanzouConfiguration
{
  try LanzouConfiguration(
    authentication: authentication,
    accountBaseURL: URL(string: "https://pc.example.invalid")!,
    shareBaseURL: URL(string: "https://share.example.invalid")!)
}

private func auditResponse(_ body: String, status: Int = 200, headers: [String: String] = [:])
  -> HTTPResponse
{
  HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

private func auditForm(_ request: URLRequest) -> [String: String] {
  String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&").reduce(into: [:]
  ) { result, item in
    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if pair.count == 2 {
      result[String(pair[0]).removingPercentEncoding ?? ""] =
        String(pair[1]).removingPercentEncoding ?? ""
    }
  }
}

private actor AuditHTTP: HTTPTransport {
  let handler: @Sendable (URLRequest, Int) throws -> HTTPResponse
  private(set) var requests: [URLRequest] = []
  init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> HTTPResponse) {
    self.handler = handler
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try handler(request, requests.filter { $0.url?.path == request.url?.path }.count)
  }
}

private let accountHTML = #"<script>uid='local'; var vei='local-vei';</script>"#
private let fileHTML =
  #"<title>file.bin - 蓝奏云</title><div class="fileinfo"></div><iframe src="/inner"></iframe>"#
private let requestHTML =
  #"<script>$.ajax({url:'/ajaxm.php?file=1',data:{'action':'downprocess','sign':'valid'}});</script>"#

@Test func protectedFolderUsesFolderRequestAndPassword() async throws {
  let html =
    #"<div id='infos'></div><div id='passwddiv'></div><script>var signature='folder-sign'; $.ajax({url:'/filemoreajax.php',data:{'task':'5','t':signature,'pg':pg,'pwd':pwd}});</script>"#
  let parsed = try LanzouSharePage.parse(
    html, url: URL(string: "https://share.example.invalid/folder")!)
  #expect(!parsed.isFile)
  #expect(parsed.requiresPassword)
  let http = AuditHTTP { request, _ in
    if request.url?.path == "/folder" { return auditResponse(html) }
    if request.url?.path == "/filemoreajax.php" {
      #expect(auditForm(request)["pwd"] == "password")
      #expect(auditForm(request)["t"] == "folder-sign")
      return auditResponse(#"{"zt":1,"text":[]}"#)
    }
    return HTTPResponse(status: 404)
  }
  let provider = LanzouProvider(
    configuration: try auditConfiguration(
      .share(url: URL(string: "https://share.example.invalid/folder")!, password: "password")),
    transport: http)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).isEmpty)
}

@Test func downloadScriptIgnoresCommentsStringsAndUnrelatedAjax() throws {
  let html = #"""
    <!-- <script>$.ajax({url:'/ajaxm.php?file=9',data:{'sign':'html-comment'}});</script> -->
    <div>url:'/ajaxm.php?file=7'; data:{'sign':'html-text'}</div>
    <script>
      var bait = "url:'/ajaxm.php?file=8'; data:{'sign':'string'}";
      // $.ajax({url:'/ajaxm.php?file=6',data:{'sign':'line-comment'}});
      /* $.ajax({url:'/ajaxm.php?file=5',data:{'sign':'block-comment'}}); */
      $.ajax({url:'/analytics',data:{'sign':'unrelated'}});
      var actual='chosen';
      $.ajax({url:'/ajaxm.php?file=1',data:{'action':'downprocess','sign':actual}});
    </script>
    """#
  let request = try LanzouScript.request(
    in: html, endpointContains: ["/ajaxm.php", "/ajaxfile.php"])
  #expect(request.endpoint == "/ajaxm.php?file=1")
  #expect(request.fields == ["action": "downprocess", "sign": "chosen"])
  #expect(throws: LanzouError.invalidResponse) {
    try LanzouScript.request(in: requestHTML + requestHTML, endpointContains: ["/ajaxm.php"])
  }
}

@Test(arguments: [false, true])
func repeatedRangesReuseDownloadLinkAndRefreshRejectedLink(expire: Bool) async throws {
  let http = AuditHTTP { request, count in
    switch request.url?.path {
    case "/share": return auditResponse(fileHTML)
    case "/inner": return auditResponse(requestHTML)
    case "/ajaxm.php":
      return auditResponse("{\"zt\":1,\"url\":\"https://download.example.invalid/file/\(count)\"}")
    case "/file/1", "/file/2":
      if request.httpMethod == "HEAD" {
        return HTTPResponse(status: 200, headers: ["Content-Length": "4"])
      }
      if expire, request.url?.path == "/file/1" { return HTTPResponse(status: 403) }
      let start = request.value(forHTTPHeaderField: "Range") == "bytes=0-1" ? 0 : 2
      return HTTPResponse(
        status: 206, headers: ["Content-Range": "bytes \(start)-\(start + 1)/4"],
        body: Data([UInt8(start), UInt8(start + 1)]))
    default: return HTTPResponse(status: 404)
    }
  }
  let provider = LanzouProvider(
    configuration: try auditConfiguration(
      .share(url: URL(string: "https://share.example.invalid/share")!, password: nil)),
    transport: http)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  var bytes = Data()
  for range: Range<Int64> in [0..<2, 2..<4] {
    for try await chunk in try await provider.read(RemotePath("/file.bin"), range: range) {
      bytes.append(chunk)
    }
  }
  #expect(bytes == Data([0, 1, 2, 3]))
  #expect(await http.requests.filter { $0.url?.path == "/ajaxm.php" }.count == (expire ? 2 : 1))
}

@Test func invalidAccountCookieIsRejectedBeforeSessionConstruction() {
  for cookie in ["broken", ";", "bad name=value", "a=b\r\nInjected: x"] {
    #expect(throws: LanzouError.invalidConfiguration) {
      try auditConfiguration(.accountCookie(cookie))
    }
  }
}

@Test func rotatedCookieIsRetainedAndRetriedAfterPersistenceFailure() async throws {
  let fails = Mutex(true)
  let saved = Mutex<[String]>([])
  let http = AuditHTTP { request, count in
    guard request.url?.path == "/mydisk.php" else { return HTTPResponse(status: 404) }
    if count == 2 { #expect(request.value(forHTTPHeaderField: "Cookie") == "phpdisk_info=rotated") }
    return auditResponse(
      accountHTML,
      headers: count == 1 ? ["Set-Cookie": "phpdisk_info=rotated; Path=/; Secure"] : [:])
  }
  let session = LanzouSession(
    configuration: try auditConfiguration(.accountCookie("phpdisk_info=old")), transport: http,
    persistAccountCookie: { cookie in
      if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
      saved.withLock { $0.append(cookie) }
    })
  await #expect(throws: CocoaError.self) { try await session.connect() }
  await #expect(throws: CocoaError.self) { try await session.connect() }
  #expect(await http.requests.count == 1)
  fails.withLock { $0 = false }
  try await session.connect()
  #expect(saved.withLock { $0 } == ["phpdisk_info=rotated"])
}

@Test func relativeFileDatesStayStableWithinSession() async throws {
  let http = AuditHTTP { request, _ in
    if request.url?.path == "/mydisk.php" { return auditResponse(accountHTML) }
    let fields = auditForm(request)
    if fields["task"] == "5", fields["pg"] == "1" {
      return auditResponse(
        #"{"zt":1,"text":[{"id":"file","name_all":"file.bin","size":4,"time":"2分钟前"}]}"#)
    }
    return auditResponse(#"{"zt":1,"text":[]}"#)
  }
  let session = LanzouSession(
    configuration: try auditConfiguration(.accountCookie("a=b")), transport: http)
  try await session.connect()
  let first = try await session.accountChildren(folderID: "-1")
  let second = try await session.accountChildren(folderID: "-1")
  #expect(first.first?.modified == second.first?.modified)
}

private actor DelayedDirectoryHTTP: HTTPTransport {
  private var pending: CheckedContinuation<HTTPResponse, Never>?
  let started = TestEvent()
  private var fileLists = 0
  var isWaiting: Bool { pending != nil }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path == "/mydisk.php" { return auditResponse(accountHTML) }
    guard request.url?.path == "/doupload.php" else { return HTTPResponse(status: 404) }
    let fields = auditForm(request)
    if fields["task"] == "5", fields["pg"] == "1" {
      fileLists += 1
      if fileLists == 1 {
        return await withCheckedContinuation {
          pending = $0
          started.signal()
        }
      }
      return auditResponse(#"{"zt":1,"text":[{"id":"new","name_all":"new.bin","size":4}]}"#)
    }
    return auditResponse(#"{"zt":1,"text":[]}"#)
  }
  func releaseOldListing() {
    pending?.resume(
      returning: auditResponse(#"{"zt":1,"text":[{"id":"old","name_all":"old.bin","size":4}]}"#))
    pending = nil
  }
}

@Test(arguments: [false, true])
func staleLanzouListingCannotRepopulatePathCache(reconnect: Bool) async throws {
  let http = DelayedDirectoryHTTP()
  let provider = LanzouProvider(
    configuration: try auditConfiguration(.accountCookie("a=b")), transport: http)
  try await provider.connect()
  let old = Task { try await provider.list(RemotePath("/")) }
  defer {
    Task { await http.releaseOldListing() }
    old.cancel()
  }
  try await http.started.wait()
  try #require(await http.isWaiting)
  if reconnect {
    await provider.disconnect()
    try await provider.connect()
  }
  let current = try await provider.list(RemotePath("/"))
  #expect(current.map(\.name) == ["new.bin"])
  await http.releaseOldListing()
  await #expect(throws: CancellationError.self) { _ = try await old.value }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/old.bin"))
  }
  #expect(try await provider.stat(RemotePath("/new.bin")).size == 4)
}

@Test func scriptFormValuesDecodeSeparatorsOnlyOnce() throws {
  let html =
    #"<script>$.ajax({url:'/ajaxm.php?file=1',data:'action=downprocess&sign=a%26b%2Bc%2520'});</script>"#
  let request = try LanzouScript.request(in: html, endpointContains: ["/ajaxm.php"])
  #expect(request.fields["sign"] == "a&b+c%20")
  let escaped =
    #"<script>var sign='\x61\u0062'; $.ajax({url:'/ajaxm.php?file=1',data:{sign:sign}});</script>"#
  #expect(
    try LanzouScript.request(in: escaped, endpointContains: ["/ajaxm.php"]).fields["sign"] == "ab")
}

@Test func protectedShareNeverFollowsForeignFrameWithPassword() async throws {
  let http = AuditHTTP { request, _ in
    guard request.url?.host == "share.example.invalid" else {
      Issue.record("不应请求外站frame")
      return HTTPResponse(status: 404)
    }
    return auditResponse(
      #"<title>file.bin - 蓝奏云</title><div class="fileinfo"></div><div id="passwddiv"></div><iframe src="https://outside.invalid/frame"></iframe>"#
    )
  }
  let session = LanzouSession(
    configuration: try auditConfiguration(
      .share(url: URL(string: "https://share.example.invalid/file")!, password: "secret")),
    transport: http)
  try await session.connect()
  await #expect(throws: LanzouError.invalidResponse) {
    _ = try await session.shareDownloadURL(
      url: URL(string: "https://share.example.invalid/file")!, password: "secret")
  }
  #expect(await http.requests.allSatisfy { $0.url?.host == "share.example.invalid" })
}

@Test func shareHTTPRejectionDoesNotRequireAccountLogin() async throws {
  let http = AuditHTTP { _, _ in HTTPResponse(status: 403) }
  let session = LanzouSession(
    configuration: try auditConfiguration(
      .share(url: URL(string: "https://share.example.invalid/file")!, password: nil)),
    transport: http)
  await #expect(throws: LanzouError.http(403)) { try await session.connect() }
  #expect(!LanzouError.http(403).requiresLogin)
  #expect(!LanzouError.invalidPassword.requiresLogin)
  let account = LanzouSession(
    configuration: try auditConfiguration(.accountCookie("a=b")), transport: http)
  await #expect(throws: LanzouError.authenticationExpired) { try await account.connect() }
  #expect(LanzouError.authenticationExpired.requiresLogin)
}

@Test func passwordFunctionMarkerIgnoresStringBait() throws {
  let base = #"<title>file.bin - 蓝奏云</title><div class="fileinfo"></div>"#
  let url = URL(string: "https://share.example.invalid/file")!
  #expect(
    try LanzouSharePage.parse(base + #"<script>function pwdload() {}</script>"#, url: url)
      .requiresPassword)
  #expect(
    try !LanzouSharePage.parse(base + #"<script>var note='pwdload';</script>"#, url: url)
      .requiresPassword)
}

@Test func protectedShareDoesNotRebindPasswordAfterCrossOriginRedirect() async throws {
  let http = AuditHTTP { _, _ in
    HTTPResponse(
      status: 200, body: Data((fileHTML + requestHTML).utf8),
      url: URL(string: "https://outside.invalid/file")!)
  }
  let provider = LanzouProvider(
    configuration: try auditConfiguration(
      .share(url: URL(string: "https://share.example.invalid/file")!, password: "secret")),
    transport: http)
  await #expect(throws: LanzouError.invalidResponse) { try await provider.connect() }
  #expect(await http.requests.count == 1)
}
