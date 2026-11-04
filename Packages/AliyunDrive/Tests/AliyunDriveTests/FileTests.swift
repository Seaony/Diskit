@testable import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import AliyunDrive

private typealias FileSecrets = TestSecretStore

private struct FileReply: Sendable {
  let endpoint: String
  let response: HTTPResponse
  init(
    _ endpoint: String, status: Int = 200, json: [String: Any] = [:],
    headers: [String: String] = [:]
  ) {
    self.endpoint = endpoint
    self.response = HTTPResponse(
      status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: json))
  }
  init(_ endpoint: String, status: Int = 200, bytes: Data, headers: [String: String] = [:]) {
    self.endpoint = endpoint
    self.response = HTTPResponse(status: status, headers: headers, body: bytes)
  }
}

private actor FileHTTP: HTTPTransport {
  var replies: [FileReply]
  var requests: [URLRequest] = []
  init(_ replies: [FileReply]) { self.replies = replies }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url!.path
    if path == "/adrive/v1.0/user/getDriveInfo" {
      return FileReply(
        "",
        json: [
          "default_drive_id": "drive", "user_id": "user", "name": "用户",
          "folder_id": "authorized-root",
        ]
      ).response
    }
    if path == "/adrive/v1.0/user/getSpaceInfo" {
      return FileReply(
        "", json: ["personal_space_info": ["total_size": 10_000_000, "used_size": 4_000_000]]
      ).response
    }
    guard !replies.isEmpty else {
      Issue.record("出现未预期请求 \(path)")
      throw RemoteError.protocolError
    }
    let next = replies.removeFirst()
    #expect(path == next.endpoint || path == "/adrive/v1.0/openFile/" + next.endpoint)
    return next.response
  }
  func fileRequests() -> [URLRequest] { requests.filter { !$0.url!.path.contains("/user/") } }
}

private func file(_ id: String, _ name: String, size: Int64 = 3, folder: Bool = false) -> [String:
  Any]
{
  [
    "file_id": id, "name": name, "type": folder ? "folder" : "file", "size": size,
    "updated_at": "2026-01-01T00:00:00.000Z",
  ]
}
private func list(_ items: [[String: Any]], marker: String = "") -> FileReply {
  FileReply("list", json: ["items": items, "next_marker": marker])
}
private func setup(_ replies: [FileReply]) throws -> (AliyunProvider, FileHTTP) {
  let secrets = FileSecrets()
  let http = FileHTTP(replies)
  let config = AliyunConfiguration(
    clientID: "id", clientSecret: "secret", redirectURI: "kayoi://oauth")
  let authorization = AliyunStoredAuthorization(
    accessToken: "access", refreshToken: "refresh", expiresAt: Date.distantFuture.timeIntervalSince1970,
    configuration: config)
  try secrets.write(JSONEncoder().encode(authorization), for: "test.authorization")
  return (
    AliyunProvider(
      session: AliyunSession(
        secretKey: "test.authorization", secrets: secrets, configuration: config, transport: http)),
    http
  )
}
private func body(_ request: URLRequest) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}
private func local(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try data.write(to: url)
  return url
}
private func created(_ id: String = "new", url: String = "https://files.example/part") -> FileReply
{
  FileReply(
    "create",
    json: [
      "file_id": id, "upload_id": "upload", "rapid_upload": false,
      "part_info_list": [["part_number": 1, "upload_url": url]],
    ])
}

@Test func aliyunPaginationReadsAllMarkersAndHonorsAuthorizedRoot() async throws {
  let first = (0..<100).map { file("f\($0)", "file\($0)") }
  let (provider, http) = try setup([list(first, marker: "page2"), list([file("f100", "file100")])])
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.count == 101)
  let requests = await http.fileRequests()
  #expect(try body(requests[0])["parent_file_id"] as? String == "authorized-root")
  #expect(try body(requests[0])["limit"] as? Int == 100)
  #expect(try body(requests[1])["marker"] as? String == "page2")
  #expect(await http.replies.isEmpty)
}

@Test func aliyunMultipartZeroExactAndRemainderBoundaries() throws {
  let size = AliyunMultipart.defaultPartSize
  #expect(try AliyunMultipart.parts(size: 0) == [AliyunPart(number: 1, offset: 0, length: 0)])
  #expect(try AliyunMultipart.parts(size: size).map(\.length) == [size])
  #expect(try AliyunMultipart.parts(size: size * 2).map(\.length) == [size, size])
  #expect(
    try AliyunMultipart.parts(size: size * 2 + 7) == [
      AliyunPart(number: 1, offset: 0, length: size),
      AliyunPart(number: 2, offset: size, length: size),
      AliyunPart(number: 3, offset: size * 2, length: 7),
    ])
}

@Test func aliyunRenameInvalidatesOldPathAndKeepsNewIdentity() async throws {
  let directory = file("folder", "A", folder: true)
  let old = file("original", "x")
  let renamed = file("original", "y")
  let (provider, http) = try setup([
    list([directory]), list([old]), list([old]), FileReply("update", json: renamed),
    list([renamed]), FileReply("get", json: renamed),
  ])
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  _ = try await provider.list(RemotePath("/A"))
  try await provider.move(RemotePath("/A/x"), to: RemotePath("/A/y"))
  await #expect(throws: RemoteError.posix(ENOENT)) { try await provider.stat(RemotePath("/A/x")) }
  #expect(try await provider.stat(RemotePath("/A/y")).name == "y")
  let requests = await http.fileRequests()
  #expect(try body(requests[3])["file_id"] as? String == "original")
  #expect(await http.replies.isEmpty)
}

@Test func aliyunCrossDirectoryRenameAvoidsOriginalNameCollision() async throws {
  let old = file("original", "report.txt")
  let (provider, http) = try setup([
    list([file("a", "A", folder: true), file("b", "B", folder: true)]),
    list([old]), list([file("existing", "report.txt")]),
    FileReply("move", json: ["file_id": "original"]),
  ])
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  _ = try await provider.list(RemotePath("/A"))
  try await provider.move(RemotePath("/A/report.txt"), to: RemotePath("/B/final.txt"))
  let requests = await http.fileRequests()
  let moved = try #require(requests.first { $0.url!.path.hasSuffix("/move") })
  #expect(try body(moved)["new_name"] as? String == "final.txt")
  #expect(try body(moved)["check_name_mode"] as? String == "refuse")
  #expect(!requests.contains { $0.url!.path.hasSuffix("/update") })
  #expect(await http.replies.isEmpty)
}

@Test func aliyunRangeSurvivesExpiredURLAndNeverSendsBearerToStorage() async throws {
  let record = file("video", "movie", size: 1024)
  let expiry = "2099-01-01T00:00:00Z"
  let (provider, http) = try setup([
    list([record]), FileReply("get", json: record),
    FileReply(
      "getDownloadUrl",
      json: ["url": "https://files.example/expired", "expiration": expiry, "method": "GET"]),
    FileReply("/expired", status: 403),
    FileReply(
      "getDownloadUrl",
      json: ["url": "https://files.example/current", "expiration": expiry, "method": "GET"]),
    FileReply(
      "/current", status: 206, bytes: Data(repeating: 7, count: 10),
      headers: ["Content-Range": "bytes 10-19/1024"]),
  ])
  try await provider.connect()
  var data = Data()
  for try await chunk in try await provider.read(RemotePath("/movie"), range: 10..<20) {
    data.append(chunk)
  }
  #expect(data == Data(repeating: 7, count: 10))
  let downloads = await http.fileRequests().filter { $0.url?.host == "files.example" }
  #expect(downloads.count == 2)
  for request in downloads {
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }
}

@Test func aliyunRejectsRangeWithFullBodyOrWrongContentRange() async throws {
  for response in [
    FileReply("/file", status: 200, bytes: Data(repeating: 0, count: 1024)),
    FileReply(
      "/file", status: 206, bytes: Data(repeating: 0, count: 10),
      headers: ["Content-Range": "bytes 0-9/1024"]),
  ] {
    let record = file("video", "movie", size: 1024)
    let (provider, _) = try setup([
      list([record]), FileReply("get", json: record),
      FileReply(
        "getDownloadUrl",
        json: [
          "url": "https://files.example/file", "expiration": "2099-01-01T00:00:00Z",
          "method": "GET",
        ]), response,
    ])
    try await provider.connect()
    await #expect(throws: RemoteError.protocolError) {
      try await provider.read(RemotePath("/movie"), range: 10..<20)
    }
  }
}

@Test func aliyunUploadRefreshesExpiredPartURLBeforeCompleting() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]), created(url: "https://files.example/expired"), FileReply("/expired", status: 403),
    FileReply(
      "getUploadUrl",
      json: ["part_info_list": [["part_number": 1, "upload_url": "https://files.example/fresh"]]]),
    FileReply("/fresh", status: 200), FileReply("complete", json: file("new", "file")),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/file"), from: url)
  let requests = await http.fileRequests()
  let uploads = requests.filter { $0.httpMethod == "PUT" }
  #expect(uploads.count == 2)
  #expect(uploads.allSatisfy { $0.httpBody == Data("new".utf8) })
  #expect(uploads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
  #expect(requests.last?.url?.path.hasSuffix("/complete") == true)
  #expect(await http.replies.isEmpty)
}

@Test func aliyunReplacementCompletesNewFileBeforeTrashingOldFile() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([file("old", "same")]), created(), FileReply("/part"),
    FileReply("complete", json: file("new", "same")), FileReply("recyclebin/trash"),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/same"), from: url)
  let requests = await http.fileRequests()
  #expect(try body(requests[1])["check_name_mode"] as? String == "ignore")
  #expect(requests[3].url!.path.hasSuffix("/complete"))
  #expect(try body(requests[4])["file_id"] as? String == "old")
  #expect(requests.allSatisfy { !$0.url!.path.hasSuffix("/delete") })
}

@Test func aliyunFailedNewUploadNeverTrashesOriginal() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([file("old", "same")]), created(), FileReply("/part", status: 500),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.write(RemotePath("/same"), from: url)
  }
  let requests = await http.fileRequests()
  #expect(
    requests.allSatisfy { !$0.url!.path.hasSuffix("/trash") && !$0.url!.path.hasSuffix("/delete") })
}

@Test func aliyunFailedOldTrashReportsWithoutRemovingNewUpload() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([file("old", "same")]), created(), FileReply("/part"),
    FileReply("complete", json: file("new", "same")), FileReply("recyclebin/trash", status: 403),
  ])
  try await provider.connect()
  await #expect(throws: AliyunFileError.replacementCleanupFailed) {
    try await provider.write(RemotePath("/same"), from: url)
  }
  let requests = await http.fileRequests()
  let trash = try #require(requests.last)
  #expect(try body(trash)["file_id"] as? String == "old")
  #expect(requests.count == 5)
}

@Test func aliyunMultipleExistingNamesRejectWithoutCreatingOrDeleting() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([list([file("old1", "same"), file("old2", "same")])])
  try await provider.connect()
  await #expect(throws: AliyunFileError.duplicateNames) {
    try await provider.write(RemotePath("/same"), from: url)
  }
  #expect(await http.fileRequests().count == 1)
}

@Test func aliyunRemoveUsesRecyclebinAndWaitsForAsyncTask() async throws {
  let (provider, http) = try setup([
    list([file("old", "file")]), FileReply("recyclebin/trash", json: ["async_task_id": "task"]),
    FileReply("async_task/get", json: ["state": "Succeed"]),
  ])
  try await provider.connect()
  try await provider.remove(RemotePath("/file"), recursive: false)
  let requests = await http.fileRequests()
  #expect(try body(requests[1])["file_id"] as? String == "old")
  #expect(try body(requests[2])["async_task_id"] as? String == "task")
  #expect(requests.allSatisfy { !$0.url!.path.hasSuffix("/delete") })
}

@Test func aliyunMultipartUploadSendsOrderedExactPartBytes() async throws {
  let partSize = Int(AliyunMultipart.defaultPartSize)
  let first = Data(repeating: 0xa1, count: partSize)
  let last = Data(repeating: 0xb2, count: 17)
  let url = try local(first + last)
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]),
    FileReply(
      "create",
      json: [
        "file_id": "new", "upload_id": "upload", "rapid_upload": false,
        "part_info_list": [
          ["part_number": 1, "upload_url": "https://files.example/part1"],
          ["part_number": 2, "upload_url": "https://files.example/part2"],
        ],
      ]),
    FileReply("/part1"), FileReply("/part2"),
    FileReply("complete", json: file("new", "large", size: Int64(partSize + 17))),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/large"), from: url)
  let requests = await http.fileRequests()
  let uploads = requests.filter { $0.httpMethod == "PUT" }
  #expect(uploads.count == 2)
  #expect(uploads[0].httpBody == first)
  #expect(uploads[1].httpBody == last)
  let parts = try #require(try body(requests[1])["part_info_list"] as? [[String: Int]])
  #expect(parts.map { $0["part_number"] } == [1, 2])
  #expect(requests.last?.url?.path.hasSuffix("/complete") == true)
}

@Test func aliyunInvalidCompletedSizeNeverTrashesOriginal() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([file("old", "same")]), created(), FileReply("/part"),
    FileReply("complete", json: file("new", "same", size: 1)),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.write(RemotePath("/same"), from: url)
  }
  let requests = await http.fileRequests()
  #expect(requests.allSatisfy { !$0.url!.path.hasSuffix("/trash") })
}

@Test(arguments: [false, true])
func aliyunMkdirReportsExistingNameForFilesAndDirectories(directory: Bool) async throws {
  let (provider, http) = try setup([list([file("existing", "same", folder: directory)])])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/same"))
  }
  #expect(await http.fileRequests().count == 1)
}

private actor CacheRaceHTTP: HTTPTransport {
  let fresh: Bool
  var listCount = 0
  var removed = false
  private var suspended: CheckedContinuation<HTTPResponse, Never>?
  private var started: [CheckedContinuation<Void, Never>] = []
  init(fresh: Bool = false) { self.fresh = fresh }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let endpoint = request.url?.lastPathComponent ?? ""
    switch endpoint {
    case "getDriveInfo":
      return FileReply(
        "",
        json: ["default_drive_id": "drive", "user_id": "user", "name": "user", "folder_id": "root"]
      ).response
    case "getSpaceInfo":
      return FileReply("", json: ["personal_space_info": ["total_size": 100, "used_size": 0]])
        .response
    case "list":
      listCount += 1
      if listCount == 2 {
        return await withCheckedContinuation { continuation in
          suspended = continuation
          let waiting = started
          started.removeAll()
          waiting.forEach { $0.resume() }
        }
      }
      return list(listCount == 1 ? [file("old", "old")] : (fresh ? [file("new", "new")] : []))
        .response
    case "trash":
      removed = true
      return FileReply("").response
    case "get":
      let id = try body(request)["file_id"] as? String
      guard id == "new", fresh else { throw RemoteError.posix(ENOENT) }
      return FileReply("", json: file("new", "new")).response
    default: throw RemoteError.protocolError
    }
  }
  func waitForSuspendedList() async {
    if suspended != nil { return }
    await withCheckedContinuation { started.append($0) }
  }
  func completeOldList() {
    suspended?.resume(returning: list([file("old", "old")]).response)
    suspended = nil
  }
}

private func raceProvider(
  _ http: any HTTPTransport, taskTimeout: Duration = .seconds(30),
  taskDeadline: HTTPProgressDeadline? = nil
) throws -> AliyunProvider {
  let secrets = MemorySecretStore()
  let configuration = AliyunConfiguration(
    clientID: "id", clientSecret: "local", redirectURI: "kayoi://oauth")
  let authorization = AliyunStoredAuthorization(
    accessToken: "access", refreshToken: "refresh", expiresAt: Date.distantFuture.timeIntervalSince1970,
    configuration: configuration)
  try secrets.write(JSONEncoder().encode(authorization), for: "account")
  return AliyunProvider(
    session: AliyunSession(
      secretKey: "account", secrets: secrets, configuration: configuration, transport: http),
    taskTimeout: taskTimeout, taskDeadline: taskDeadline)
}

@Test func aliyunLateListingCannotRestoreDeletedFile() async throws {
  let http = CacheRaceHTTP()
  let provider = try raceProvider(http)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  let delayed = Task { try await provider.list(RemotePath("/")) }
  await http.waitForSuspendedList()
  try await provider.remove(RemotePath("/old"), recursive: false)
  await http.completeOldList()
  await #expect(throws: RemoteError.posix(EAGAIN)) { _ = try await delayed.value }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/old"))
  }
  #expect(await http.removed)
}

@Test func aliyunOlderListingCannotReplaceNewerSnapshot() async throws {
  let http = CacheRaceHTTP(fresh: true)
  let provider = try raceProvider(http)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  let delayed = Task { try await provider.list(RemotePath("/")) }
  await http.waitForSuspendedList()
  #expect(try await provider.list(RemotePath("/")).map(\.name) == ["new"])
  await http.completeOldList()
  await #expect(throws: RemoteError.posix(EAGAIN)) { _ = try await delayed.value }
  #expect(try await provider.stat(RemotePath("/new")).name == "new")
  #expect(await http.listCount == 3)
}

@Test func aliyunOnlyExpiredAccountRequiresLogin() {
  #expect(AliyunError.loginRequired.requiresLogin)
  for error in [
    AliyunError.invalidState, .missingConfiguration, .invalidResponse, .rateLimited,
    .authorizationFailed(403), .authorizationFailed(500),
  ] {
    #expect(!error.requiresLogin)
  }
}

@Test func aliyunRepeatedRangeReadReusesUnexpiredDownloadLink() async throws {
  let record = file("video", "movie", size: 1024)
  let (provider, http) = try setup([
    list([record]), FileReply("get", json: record),
    FileReply(
      "getDownloadUrl",
      json: [
        "url": "https://files.example/current", "expiration": "2099-01-01T00:00:00Z",
        "method": "GET",
      ]),
    FileReply(
      "/current", status: 206, bytes: Data([1, 2]), headers: ["Content-Range": "bytes 0-1/1024"]),
    FileReply("get", json: record),
    FileReply(
      "/current", status: 206, bytes: Data([3, 4]), headers: ["Content-Range": "bytes 2-3/1024"]),
  ])
  try await provider.connect()
  let ranges: [Range<Int64>] = [0..<2, 2..<4]
  for range in ranges {
    var count = 0
    for try await bytes in try await provider.read(RemotePath("/movie"), range: range) {
      count += bytes.count
    }
    #expect(count == 2)
  }
  let requests = await http.fileRequests()
  #expect(requests.filter { $0.url?.lastPathComponent == "getDownloadUrl" }.count == 1)
}

private actor SlowAliyunTaskHTTP: HTTPTransport {
  nonisolated let pollStarted = TestEvent()
  nonisolated let pollRelease = TestEvent()
  let base = FileHTTP([
    list([file("old", "file")]),
    FileReply("recyclebin/trash", json: ["async_task_id": "task"]),
  ])
  var cancelled = false
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path.hasSuffix("/async_task/get") == true {
      pollStarted.signal()
      do { try await pollRelease.wait() } catch {
        cancelled = true
        throw error
      }
      return FileReply("", json: ["state": "Succeed"]).response
    }
    return try await base.send(request)
  }
}

@Test func aliyunTaskDeadlineCancelsSlowPollBeforeReportingSuccess() async throws {
  let http = SlowAliyunTaskHTTP()
  let clock = ManualTestClock()
  let deadline = HTTPProgressDeadline(
    interval: .seconds(30),
    clock: DeadlineClock(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }))
  let provider = try raceProvider(http, taskDeadline: deadline)
  try await provider.connect()
  let removal = Task { try await provider.remove(RemotePath("/file"), recursive: false) }
  try await http.pollStarted.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await removal.value }
  #expect(await http.cancelled)
}
