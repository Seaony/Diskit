import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import ChinaWebDrive

private let auditRoute = Data(
  #"{"success":true,"code":"0000","data":{"routePolicyList":[{"modName":"personal","httpsUrl":"https://personal-kd-njs.yun.139.com/hcy"}]}}"#
    .utf8)

private func auditResponse(_ data: Any, status: Int = 200) throws -> HTTPResponse {
  HTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: data))
}

private actor MobileMoveHTTP: HTTPTransport {
  struct Entry: Sendable {
    var id: String
    var parent: String
    var name: String
    var type = "file"
    var json: [String: Any] {
      ["fileId": id, "parentFileId": parent, "name": name, "type": type, "size": 1]
    }
  }
  var items = [
    Entry(id: "moving", parent: "/", name: "old"),
    Entry(id: "source-existing", parent: "/", name: "new"),
    Entry(id: "destination", parent: "/", name: "dest", type: "folder"),
    Entry(id: "target-existing", parent: "destination", name: "old"),
  ]
  let failFinalRename: Bool
  let failRecovery: Bool
  init(failFinalRename: Bool = false, failRecovery: Bool = false) {
    self.failFinalRename = failFinalRename
    self.failRecovery = failRecovery
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path.hasSuffix("qryRoutePolicy") == true {
      return HTTPResponse(status: 200, body: auditRoute)
    }
    let body = try #require(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let path = request.url?.path ?? ""
    if path.hasSuffix("file/list") {
      let parent = try #require(body["parentFileId"] as? String)
      return try auditResponse([
        "success": true, "data": ["items": items.filter { $0.parent == parent }.map(\.json)],
      ])
    }
    if path.hasSuffix("file/update") {
      let id = try #require(body["fileId"] as? String)
      let name = try #require(body["name"] as? String)
      let index = try #require(items.firstIndex { $0.id == id })
      if (failFinalRename && name == "new" && items[index].parent == "destination")
        || (failRecovery && name == "old")
      {
        return try auditResponse(["success": false, "message": "server failure"], status: 500)
      }
      if items.contains(where: {
        $0.id != id && $0.parent == items[index].parent && $0.name == name
      }) {
        return try auditResponse(["success": false, "message": "same name"], status: 409)
      }
      items[index].name = name
      return try auditResponse(["success": true, "data": [:]])
    }
    if path.hasSuffix("file/batchMove") {
      let id = try #require((body["fileIds"] as? [String])?.first)
      let parent = try #require(body["toParentFileId"] as? String)
      let index = try #require(items.firstIndex { $0.id == id })
      if items.contains(where: {
        $0.id != id && $0.parent == parent && $0.name == items[index].name
      }) {
        return try auditResponse(["success": false, "message": "same name"], status: 409)
      }
      items[index].parent = parent
      return try auditResponse(["success": true, "data": [:]])
    }
    return HTTPResponse(status: 404)
  }
}

private func auditSession(
  _ transport: any HTTPTransport, refresh: MobileCloudSession.Refresh? = nil
) -> MobileCloudSession {
  MobileCloudSession(
    credentials: MobileCloudCredentials(phone: "local", token: "old"), refresh: refresh,
    transport: transport)
}

@Test func mobileCrossDirectoryRenamePreservesBothExistingNames() async throws {
  let http = MobileMoveHTTP()
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  try await provider.move(RemotePath("/old"), to: RemotePath("/dest/new"))
  let items = await http.items
  #expect(items.first { $0.id == "moving" }?.name == "new")
  #expect(items.first { $0.id == "moving" }?.parent == "destination")
  #expect(items.first { $0.id == "source-existing" }?.name == "new")
  #expect(items.first { $0.id == "target-existing" }?.name == "old")
}

@Test func mobileFailedFinalRenameRestoresOriginalLocation() async throws {
  let http = MobileMoveHTTP(failFinalRename: true)
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  await #expect(throws: RemoteError.http(500)) {
    try await provider.move(RemotePath("/old"), to: RemotePath("/dest/new"))
  }
  let item = await http.items.first { $0.id == "moving" }
  #expect(item?.name == "old")
  #expect(item?.parent == "/")
  #expect(try await provider.stat(RemotePath("/old")).name == "old")
}

@Test func mobileFailedRollbackReportsLastConfirmedLocation() async throws {
  let http = MobileMoveHTTP(failFinalRename: true, failRecovery: true)
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  do {
    try await provider.move(RemotePath("/old"), to: RemotePath("/dest/new"))
    Issue.record("回滚失败不应成功")
  } catch let error as MobileCloudMoveFailure {
    #expect(error.lastConfirmedPath.hasPrefix("/.kayoi-move-"))
    #expect(error.original as? RemoteError == .http(500))
    #expect(error.recovery as? RemoteError == .http(500))
  }
  #expect(await http.items.count == 4)
}

private actor MobileAuditScript: HTTPTransport {
  var replies: [HTTPResponse]
  var requests: [URLRequest] = []
  init(_ replies: [HTTPResponse]) { self.replies = replies }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !replies.isEmpty else { throw RemoteError.protocolError }
    return replies.removeFirst()
  }
}

@Test(arguments: [false, true])
func mobileExistingCreateResultIsNeverDeleted(directory: Bool) async throws {
  let http = MobileAuditScript([
    HTTPResponse(status: 200, body: auditRoute),
    try auditResponse(["success": true, "data": ["items": []]]),
    try auditResponse([
      "success": true, "data": ["fileId": "existing", "fileName": "another-name", "exist": true],
    ]),
  ])
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1]).write(to: file)
  await #expect(throws: RemoteError.posix(EEXIST)) {
    if directory {
      try await provider.makeDirectory(RemotePath("/new"))
    } else {
      try await provider.write(RemotePath("/new"), from: file)
    }
  }
  #expect(await http.requests.count == 3)
  #expect(await http.requests.allSatisfy { $0.url?.path.contains("Trash") != true })
}

@Test func chinaWebCompactDateIsNotMillisecondsSinceEpoch() throws {
  let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-04T07:30:00Z"))
  #expect(ChinaWebSupport.parseDate("20261104153000") == expected)
  #expect(ChinaWebSupport.parseDate("20260230153000") == Date(timeIntervalSince1970: 0))
  #expect(ChinaWebSupport.parseDate("1700000000000").timeIntervalSince1970 == 1_700_000_000)
  #expect(ChinaWebSupport.parseDate("1700000000").timeIntervalSince1970 == 1_700_000_000)
}

private actor MobileRefreshProbe: HTTPTransport {
  var oldRequests = 0
  let rejected = TestEvent()
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path.hasSuffix("qryRoutePolicy") == true {
      return HTTPResponse(status: 200, body: auditRoute)
    }
    if request.value(forHTTPHeaderField: "Authorization") == "Basic old" {
      oldRequests += 1
      if oldRequests == 10 { rejected.signal() }
      try await rejected.wait()
      return try auditResponse(["success": false, "code": "9008"], status: 401)
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic new")
    return try auditResponse(["success": true, "data": [:]])
  }
}

@Test func mobileConcurrentRejectionsShareOneRefresh() async throws {
  let refreshes = Mutex(0)
  let http = MobileRefreshProbe()
  let session = auditSession(http) { credentials in
    refreshes.withLock { $0 += 1 }
    return MobileCloudCredentials(phone: credentials.phone, token: "new")
  }
  try await session.connect()
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<10 { group.addTask { _ = try await session.request("file/list", body: [:]) } }
    try await group.waitForAll()
  }
  #expect(refreshes.withLock { $0 } == 1)
  #expect(await http.oldRequests == 10)
}

@Test(arguments: ["captcha required", "请完成人机验证", "risk_control"])
func mobileVerificationFailureDoesNotRefreshOrRequireLogin(message: String) async throws {
  let refreshes = Mutex(0)
  let http = MobileAuditScript([
    HTTPResponse(status: 200, body: auditRoute),
    try auditResponse(["success": false, "code": "9008", "message": message], status: 403),
  ])
  let session = auditSession(http) { credentials in
    refreshes.withLock { $0 += 1 }
    return credentials
  }
  try await session.connect()
  await #expect(throws: MobileCloudError.verificationRequired) {
    _ = try await session.request("file/list", body: [:])
  }
  #expect(refreshes.withLock { $0 } == 0)
  #expect(!MobileCloudError.verificationRequired.requiresLogin)
  #expect((MobileCloudError.verificationRequired as NSError).code == Int(EAGAIN))
}

@Test func mobileServerFailureDoesNotRefreshEvenWithStaleLoginCode() async throws {
  let refreshes = Mutex(0)
  let http = MobileAuditScript([
    HTTPResponse(status: 200, body: auditRoute),
    try auditResponse(["success": false, "code": "9008"], status: 500),
  ])
  let session = auditSession(http) { credentials in
    refreshes.withLock { $0 += 1 }
    return credentials
  }
  try await session.connect()
  await #expect(throws: RemoteError.http(500)) {
    _ = try await session.request("file/list", body: [:])
  }
  #expect(refreshes.withLock { $0 } == 0)
}

@Test(arguments: [false, true])
func mobileDirectoryRejectsContradictoryDuplicateIDs(contradictory: Bool) async throws {
  let first: [String: Any] = ["fileId": "same", "name": "first", "type": "file", "size": 1]
  var second = first
  if contradictory { second["name"] = "other" }
  let http = MobileAuditScript([
    HTTPResponse(status: 200, body: auditRoute),
    try auditResponse(["success": true, "data": ["items": [first], "nextPageCursor": "next"]]),
    try auditResponse(["success": true, "data": ["items": [second]]]),
  ])
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  if contradictory {
    await #expect(throws: MobileCloudError.invalidResponse) {
      _ = try await provider.list(RemotePath("/"))
    }
  } else {
    #expect(try await provider.list(RemotePath("/")).map(\.name) == ["first"])
  }
}

private actor MobileListingRace: HTTPTransport {
  let entered: AsyncStream<Void>.Continuation
  var first: CheckedContinuation<HTTPResponse, Never>?
  var count = 0
  init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path.hasSuffix("qryRoutePolicy") == true {
      return HTTPResponse(status: 200, body: auditRoute)
    }
    guard request.url?.path.hasSuffix("file/list") == true else { return HTTPResponse(status: 404) }
    count += 1
    if count == 1 {
      entered.yield(())
      return await withCheckedContinuation { first = $0 }
    }
    return try auditResponse([
      "success": true,
      "data": ["items": [["fileId": "new", "name": "new", "type": "file", "size": 1]]],
    ])
  }
  func finishOld() throws {
    first?.resume(
      returning: try auditResponse([
        "success": true,
        "data": ["items": [["fileId": "old", "name": "old", "type": "file", "size": 1]]],
      ]))
    first = nil
  }
}

@Test(arguments: [false, true])
func mobileLateDirectoryCannotReplaceNewerState(disconnect: Bool) async throws {
  let signal = AsyncStream<Void>.makeStream()
  let http = MobileListingRace(entered: signal.continuation)
  let provider = MobileCloudProvider(session: auditSession(http))
  try await provider.connect()
  let old = Task { try await provider.list(RemotePath("/")) }
  var observed = signal.stream.makeAsyncIterator()
  _ = await observed.next()
  if disconnect {
    await provider.disconnect()
  } else {
    #expect(try await provider.list(RemotePath("/")).map(\.name) == ["new"])
  }
  try await http.finishOld()
  await #expect(throws: RemoteError.posix(EAGAIN)) { _ = try await old.value }
  if disconnect {
    await #expect(throws: RemoteError.notConnected) {
      _ = try await provider.stat(RemotePath("/new"))
    }
  } else {
    #expect(try await provider.stat(RemotePath("/new")).name == "new")
    #expect(await http.count == 2)
  }
}


@Test func mobileMoveRecoveryFailureKeepsExplicitLoginSemantics() {
  let transient = MobileCloudMoveFailure(lastConfirmedPath: "/local", original: POSIXError(.ETIMEDOUT), recovery: POSIXError(.EACCES))
  #expect(!transient.requiresLogin)
  let login = MobileCloudMoveFailure(lastConfirmedPath: "/local", original: MobileCloudError.loginRequired, recovery: POSIXError(.EIO))
  #expect(login.requiresLogin)
}
