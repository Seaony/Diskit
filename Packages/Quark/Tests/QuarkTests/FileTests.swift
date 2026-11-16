import CoreTestSupport
import Core
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Quark

private typealias FileSecrets = TestSecretStore
private struct Reply: Sendable {
  let path: String
  let response: HTTPResponse
  init(_ path: String, data: Any = [:], metadata: [String: Any] = [:]) {
    self.path = path
    response = HTTPResponse(
      status: 200,
      body: try! JSONSerialization.data(withJSONObject: [
        "status": 200, "code": 0, "data": data, "metadata": metadata,
      ]))
  }
  init(_ path: String, status: Int = 200, bytes: Data, headers: [String: String] = [:]) {
    self.path = path
    response = HTTPResponse(status: status, headers: headers, body: bytes)
  }
}
private actor FileHTTP: HTTPTransport {
  var replies: [Reply]
  var requests: [URLRequest] = []
  init(_ replies: [Reply]) { self.replies = replies }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let path = request.url!.path
    requests.append(request)
    if path.contains("/account/") {
      return HTTPResponse(
        status: 200, body: Data(#"{"success":true,"data":{"nickname":"测试","uid":"user"}}"#.utf8))
    }
    if path.hasSuffix("/config") || path.hasSuffix("/member") {
      return Reply(
        "",
        data: [
          "member_type": "NORMAL", "nickname": "测试", "nick_name": "测试", "uid": "user",
          "user_id": "user", "total_capacity": 1_000_000, "use_capacity": 100,
        ]
      ).response
    }
    guard !replies.isEmpty else {
      Issue.record("未预期请求 \(path)")
      throw RemoteError.protocolError
    }
    let reply = replies.removeFirst()
    #expect(path == reply.path || path == "/1/clouddrive" + reply.path)
    return reply.response
  }
  func files() -> [URLRequest] {
    requests.filter {
      !$0.url!.path.contains("/account/") && !$0.url!.path.hasSuffix("/config")
        && !$0.url!.path.hasSuffix("/member")
    }
  }
}
private func file(_ id: String, _ name: String, size: Int64 = 3, folder: Bool = false) -> [String:
  Any]
{
  ["fid": id, "file_name": name, "file": !folder, "size": size, "updated_at": 1_700_000_000_000]
}
private func list(_ files: [[String: Any]], total: Int? = nil) -> Reply {
  Reply("/file/sort", data: ["list": files], metadata: ["_total": total ?? files.count])
}
private func setup(_ replies: [Reply]) throws -> (QuarkProvider, FileHTTP) {
  let secrets = FileSecrets()
  try secrets.write(Data("__puus=fake-session; __pus=fake-user".utf8), for: "test.cookie")
  let http = FileHTTP(replies)
  return (
    QuarkProvider(
      session: QuarkSession(secretKey: "test.cookie", secrets: secrets, transport: http)), http
  )
}
private func local(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try data.write(to: url)
  return url
}
private func body(_ request: URLRequest) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}
private func pre(partSize: Int = 102400) -> Reply {
  Reply(
    "/file/upload/pre",
    data: [
      "task_id": "task", "upload_id": "upload", "obj_key": "objects/key",
      "upload_url": "http://oss-cn-beijing.aliyuncs.com", "fid": "new", "bucket": "test-bucket",
      "callback": ["callbackUrl": "https://drive.quark.cn/callback", "callbackBody": "body"],
      "auth_info": "auth-info",
    ], metadata: ["part_size": partSize])
}
private func auth() -> Reply {
  Reply("/file/upload/auth", data: ["auth_key": "OSS fake-signature"])
}

@Test func quarkFilesPaginationAndDecodedNames() async throws {
  let (provider, http) = try setup([
    list((0..<100).map { file("f\($0)", "x\($0)") }, total: 101),
    list([file("last", "中文 &amp; &#x1F431;")], total: 101),
  ])
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.count == 101)
  #expect(items.last?.name == "中文 & 🐱")
  let requests = await http.files()
  #expect(
    URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
      URLQueryItem(name: "_page", value: "2")) == true)
  #expect(await http.replies.isEmpty)
}
@Test func quarkHashesKnownVectorsAndChunkBoundary() throws {
  for (bytes, md5, sha1) in [
    (Data(), "d41d8cd98f00b204e9800998ecf8427e", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
    (
      Data("abc".utf8), "900150983cd24fb0d6963f7d28e17f72",
      "a9993e364706816aba3e25717850c26c9cd0d89d"
    ),
  ] {
    let url = try local(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try QuarkDigests.file(url) == QuarkDigests(md5: md5, sha1: sha1))
  }
  let bytes = Data(repeating: 0xa7, count: 65537)
  let url = try local(bytes)
  defer { try? FileManager.default.removeItem(at: url) }
  #expect(
    try QuarkDigests.file(url).md5
      == Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
}
@Test func quarkPartZeroExactRemainderAndOver100MB() throws {
  #expect(try QuarkPart.split(size: 0, partSize: 102400).map(\.length) == [0])
  #expect(try QuarkPart.split(size: 204800, partSize: 102400).map(\.length) == [102400, 102400])
  let parts = try QuarkPart.split(size: 101 * 1024 * 1024 + 17, partSize: 10 * 1024 * 1024)
  #expect(parts.count == 11)
  #expect(parts.last?.length == Int64(1024 * 1024 + 17))
}
@Test func quarkRangeRequestsAndValidation() async throws {
  for valid in [true, false] {
    let (provider, http) = try setup([
      list([file("f", "movie", size: 1024)]),
      Reply("/file/download", data: [["download_url": "https://download.quark.cn/content"]]),
      Reply(
        "/content", status: valid ? 206 : 200, bytes: Data(repeating: 7, count: 10),
        headers: ["Content-Range": "bytes 10-19/1024"]),
    ])
    try await provider.connect()
    if valid {
      var output = Data()
      for try await bytes in try await provider.read(RemotePath("/movie"), range: 10..<20) {
        output.append(bytes)
      }
      #expect(output.count == 10)
    } else {
      await #expect(throws: RemoteError.protocolError) {
        try await provider.read(RemotePath("/movie"), range: 10..<20)
      }
    }
    let request = try #require(await http.files().last)
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=fake-session") == true)
  }
  #expect(!QuarkProvider.validRange("bytes 0-9/1024", requested: 10..<20, size: 1024))
}
@Test func quarkExistingNameNeverStartsUploadOrChangesOldFile() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([list([file("old", "same")])])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(RemotePath("/same"), from: url)
  }
  #expect(await http.files().count == 1)
}
@Test func quarkMultipartSignsExactHeadersAndFinishesInOrder() async throws {
  let first = Data(repeating: 0xa1, count: 102400)
  let last = Data(repeating: 0xb2, count: 17)
  let url = try local(first + last)
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]), pre(), Reply("/file/update/hash", data: ["finish": false]), auth(),
    Reply("/objects/key", bytes: Data(), headers: ["ETag": "\"part1\""]), auth(),
    Reply("/objects/key", bytes: Data(), headers: ["ETag": "\"part2\""]), auth(),
    Reply("/objects/key", bytes: Data()), Reply("/file/upload/finish"),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/large"), from: url)
  let requests = await http.files()
  let puts = requests.filter { $0.httpMethod == "PUT" }
  #expect(puts.count == 2)
  #expect(puts[0].httpBody == first)
  #expect(puts[1].httpBody == last)
  let oss = requests.filter { $0.url!.host!.hasSuffix(".aliyuncs.com") }
  #expect(oss.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
  #expect(oss.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "OSS fake-signature" })
  let signed = requests.filter { $0.url!.path.hasSuffix("/upload/auth") }
  for (index, request) in oss.enumerated() {
    let date = try #require(request.value(forHTTPHeaderField: "x-oss-date"))
    let meta = try #require(try body(signed[index])["auth_meta"] as? String)
    #expect(meta.contains("\nx-oss-date:\(date)\n"))
    #expect(
      meta.hasSuffix(
        index < 2
          ? "/test-bucket/objects/key?partNumber=\(index+1)&uploadId=upload"
          : "/test-bucket/objects/key?uploadId=upload"))
  }
  let completed = oss[2]
  let xml = try #require(completed.httpBody)
  #expect(
    completed.value(forHTTPHeaderField: "Content-MD5")
      == Data(Insecure.MD5.hash(data: xml)).base64EncodedString())
  #expect(String(decoding: xml, as: UTF8.self).contains("<ETag>\"part2\"</ETag>"))
  let callback = try #require(
    completed.value(forHTTPHeaderField: "x-oss-callback").flatMap { Data(base64Encoded: $0) })
  #expect(
    (try JSONSerialization.jsonObject(with: callback) as? [String: String])?["callbackBody"]
      == "body")
  #expect(requests.last?.url!.path.hasSuffix("/upload/finish") == true)
  #expect(await http.replies.isEmpty)
}
@Test func quarkRapidUploadSkipsOSS() async throws {
  let url = try local(Data())
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]), pre(), Reply("/file/update/hash", data: ["finish": true]),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/empty"), from: url)
  #expect(await http.files().count == 3)
}
@Test func quarkFailedPartDoesNotFinish() async throws {
  let url = try local(Data("abc".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]), pre(), Reply("/file/update/hash", data: ["finish": false]), auth(),
    Reply("/objects/key", status: 500, bytes: Data()),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.http(500)) {
    try await provider.write(RemotePath("/new"), from: url)
  }
  #expect(await http.files().allSatisfy { !$0.url!.path.hasSuffix("/finish") })
}
@Test func quarkMkdirRenameAndTrashInvalidatePaths() async throws {
  let (provider, http) = try setup([
    list([]), Reply("/file"), list([file("f", "x")]), list([file("f", "x")]), Reply("/file/rename"),
    list([file("f", "y")]), Reply("/file/delete"),
  ])
  try await provider.connect()
  try await provider.makeDirectory(RemotePath("/dir"))
  try await provider.move(RemotePath("/x"), to: RemotePath("/y"))
  await #expect(throws: RemoteError.posix(ENOENT)) { try await provider.stat(RemotePath("/x")) }
  _ = try await provider.stat(RemotePath("/y"))
  try await provider.remove(RemotePath("/y"), recursive: false)
  let requests = await http.files()
  let deletion = try #require(requests.last)
  #expect(try body(deletion)["action_type"] as? Int == 1)
  #expect(try body(deletion)["filelist"] as? [String] == ["f"])
  #expect(await http.replies.isEmpty)
}

@Test func quarkMoveAcrossDirectoriesThenRename() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([]), Reply("/file/move"),
    Reply("/file/rename"),
  ])
  try await provider.connect()
  try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  let requests = await http.files()
  #expect(try body(requests[2])["to_pdir_fid"] as? String == "dest")
  #expect(try body(requests[2])["filelist"] as? [String] == ["f"])
  #expect(try body(requests[3])["fid"] as? String == "f")
  #expect(try body(requests[3])["file_name"] as? String == "y")
  #expect(await http.replies.isEmpty)
}
@Test func quarkExpiredDownloadRefreshPreservesRange() async throws {
  let (provider, http) = try setup([
    list([file("f", "x", size: 100)]),
    Reply("/file/download", data: [["download_url": "https://download.quark.cn/old"]]),
    Reply("/old", status: 403, bytes: Data()),
    Reply("/file/download", data: [["download_url": "https://download.quark.cn/new"]]),
    Reply("/new", status: 206, bytes: Data([7, 8]), headers: ["Content-Range": "bytes 2-3/100"]),
  ])
  try await provider.connect()
  var result = Data()
  for try await chunk in try await provider.read(RemotePath("/x"), range: 2..<4) {
    result.append(chunk)
  }
  #expect(result == Data([7, 8]))
  let downloads = await http.files().filter { $0.url?.host == "download.quark.cn" }
  #expect(downloads.count == 2)
  #expect(downloads.allSatisfy { $0.value(forHTTPHeaderField: "Range") == "bytes=2-3" })
}
@Test func quarkCookieInvalidationPropagatesFromList() async throws {
  let (provider, _) = try setup([Reply("/file/sort", status: 401, bytes: Data())])
  try await provider.connect()
  await #expect(throws: QuarkError.loginRequired) { try await provider.list(RemotePath("/")) }
}

@Test func quarkExistingDirectoryReportsConflict() async throws {
  let (provider, http) = try setup([list([file("dir", "existing", folder: true)])])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/existing"))
  }
  #expect(await http.files().count == 1)
}

@Test func quarkUploadUsesDestinationExtensionForFormat() async throws {
  let url = try local(Data())
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([]), pre(), Reply("/file/update/hash", data: ["finish": true]),
  ])
  try await provider.connect()
  try await provider.write(RemotePath("/photo.png"), from: url)
  let request = try #require(
    await http.files().first { $0.url?.path.hasSuffix("/upload/pre") == true })
  #expect(try body(request)["format_type"] as? String == "image/png")
}

@Test func quarkMoveWaitsForTaskBeforeRenaming() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([]),
    Reply("/file/move", data: ["task_id": "move-task"]),
    Reply("/task", data: ["status": 2]), Reply("/file/rename"),
  ])
  try await provider.connect()
  try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  let requests = await http.files()
  #expect(requests.map { $0.url!.lastPathComponent } == ["sort", "sort", "move", "task", "rename"])
  #expect(
    URLComponents(url: requests[3].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
      URLQueryItem(name: "task_id", value: "move-task")) == true)
}

@Test func quarkDeleteTaskFailureIsNotReportedAsSuccess() async throws {
  let (provider, http) = try setup([
    list([file("f", "x")]), Reply("/file/delete", data: ["task_id": "delete-task"]),
    Reply("/task", data: ["status": 3]),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.remove(RemotePath("/x"), recursive: false)
  }
  #expect(await http.files().last?.url?.lastPathComponent == "task")
}

@Test(arguments: [true, false])
func quarkRetriesInconsistentEmptyPageOnceWithoutDroppingRows(recovers: Bool) async throws {
  let (provider, http) = try setup([
    list([], total: 1), recovers ? list([file("f", "x")]) : list([], total: 1),
  ])
  try await provider.connect()
  if recovers {
    #expect(try await provider.list(RemotePath("/")).map(\.name) == ["x"])
  } else {
    await #expect(throws: RemoteError.protocolError) {
      _ = try await provider.list(RemotePath("/"))
    }
  }
  let requests = await http.files()
  #expect(requests.count == 2)
  #expect(
    requests.allSatisfy {
      URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "_page", value: "1")) == true
    })
}

@Test func quarkCrossDirectoryRenameAvoidsUnrelatedOriginalName() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([file("unrelated", "x")]),
    Reply("/file/rename"), Reply("/file/move", data: ["task_id": "move"]),
    Reply("/task", data: ["status": 2]), Reply("/file/rename"),
  ])
  try await provider.connect()
  try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  let requests = await http.files()
  #expect(
    requests.map { $0.url!.lastPathComponent } == [
      "sort", "sort", "rename", "move", "task", "rename",
    ])
  #expect(try body(requests[2])["fid"] as? String == "f")
  #expect((try body(requests[2])["file_name"] as? String)?.hasPrefix(".diskit-move-") == true)
  #expect(try body(requests[3])["filelist"] as? [String] == ["f"])
  #expect(try body(requests[5])["file_name"] as? String == "y")
}

@Test func quarkFailedStagedMoveRestoresOriginalName() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([file("unrelated", "x")]),
    Reply("/file/rename"), Reply("/file/move", status: 500, bytes: Data()), Reply("/file/rename"),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.http(500)) {
    try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  }
  let requests = await http.files()
  #expect(try body(requests.last!)["fid"] as? String == "f")
  #expect(try body(requests.last!)["file_name"] as? String == "x")
}

@Test func quarkFailedFinalRenameMovesBackBeforeRestoringOriginalName() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([file("unrelated", "x")]),
    Reply("/file/rename"), Reply("/file/move"), Reply("/file/rename", status: 409, bytes: Data()),
    Reply("/file/move"), Reply("/file/rename"),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.http(409)) {
    try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  }
  let requests = await http.files()
  #expect(try body(requests[5])["to_pdir_fid"] as? String == "0")
  #expect(try body(requests[6])["file_name"] as? String == "x")
}

@Test func quarkRangesReuseLinkForUnchangedFileMetadata() async throws {
  let (provider, http) = try setup([
    list([file("f", "x", size: 100)]),
    Reply("/file/download", data: [["download_url": "https://download.quark.cn/signed"]]),
    Reply(
      "/signed", status: 206, bytes: Data([1, 2]), headers: ["Content-Range": "bytes 0-1/100"]),
    Reply(
      "/signed", status: 206, bytes: Data([3, 4]), headers: ["Content-Range": "bytes 2-3/100"]),
  ])
  try await provider.connect()
  var output = Data()
  for try await bytes in try await provider.read(RemotePath("/x"), range: 0..<2) {
    output.append(bytes)
  }
  for try await bytes in try await provider.read(RemotePath("/x"), range: 2..<4) {
    output.append(bytes)
  }
  #expect(output == Data([1, 2, 3, 4]))
  #expect(await http.files().filter { $0.url?.path.hasSuffix("/file/download") == true }.count == 1)
  // 第二次读直接用列目录时记下的信息，不再重新列目录
  #expect(await http.files().filter { $0.url?.path.hasSuffix("/file/sort") == true }.count == 1)
}

@Test func quarkFailedMoveAndRecoveryPreserveBothErrors() async throws {
  let (provider, _) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]), list([file("unrelated", "x")]),
    Reply("/file/rename"), Reply("/file/move", status: 500, bytes: Data()),
    Reply("/file/rename", status: 503, bytes: Data()),
  ])
  try await provider.connect()
  do {
    try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
    Issue.record("恢复失败不能报成功")
  } catch let error as QuarkMoveRecoveryError {
    #expect(error.original as? RemoteError == .http(500))
    #expect(error.recovery as? RemoteError == .http(503))
    #expect(error.temporaryName.hasPrefix(".diskit-move-"))
  }
}

@Test(arguments: [0, 1])
func quarkPendingTaskIsPolledUntilCompleted(status: Int) async throws {
  let (provider, http) = try setup([
    list([file("f", "x")]), Reply("/file/delete", data: ["task_id": "delete-task"]),
    Reply("/task", data: ["status": status]), Reply("/task", data: ["status": 2]),
  ])
  try await provider.connect()
  try await provider.remove(RemotePath("/x"), recursive: false)
  let polls = await http.files().filter { $0.url?.lastPathComponent == "task" }
  #expect(polls.count == 2)
  #expect(
    URLComponents(url: polls[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
      URLQueryItem(name: "retry_index", value: "1")) == true)
}

@Test func quarkCrossDirectoryRenameNeverTouchesExistingFinalName() async throws {
  let (provider, http) = try setup([
    list([file("f", "x"), file("dest", "dir", folder: true)]),
    list([file("old-name", "x"), file("final-name", "y")]),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.move(RemotePath("/x"), to: RemotePath("/dir/y"))
  }
  #expect(await http.files().allSatisfy { $0.httpMethod == "GET" })
}

@Test func quarkNameEntitiesPreserveUnsupportedInputAndUnicodeBoundaries() {
  #expect(QuarkNames.decode("😀&amp;&#x1F600;&#20013;&nbsp;") == "😀&😀中\u{00a0}")
  #expect(QuarkNames.decode("&lt;&gt;&quot;&apos;") == "<>\"'")
  let unsupported = "&#xD800;&#1114112;&#999999999999;&unknown;&#X41;&amp"
  #expect(QuarkNames.decode(unsupported) == unsupported)
  #expect(QuarkNames.decode("&amp;lt;") == "&lt;")
  #expect(QuarkNames.decode("") == "")
}

@Test func quarkDuplicateNamesGetFinderStyleNamesAndHitTheRightFile() async throws {
  let url = try local(Data("new".utf8))
  defer { try? FileManager.default.removeItem(at: url) }
  let (provider, http) = try setup([
    list([file("f2", "a.txt", size: 100), file("f1", "a.txt"), file("d", "a", folder: true)]),
    Reply("/file/download", data: [["download_url": "https://download.quark.cn/second"]]),
    Reply("/second", status: 206, bytes: Data([1, 2]), headers: ["Content-Range": "bytes 0-1/100"]),
    list([file("d", "a", folder: true), file("f1", "a.txt"), file("f2", "a.txt", size: 100)]),
    Reply("/file/delete"),
  ])
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(Set(items.map(\.path.value)) == ["/a.txt", "/a (2).txt", "/a"])
  #expect(try await provider.stat(RemotePath("/a (2).txt")).size == 100)
  var bytes = Data()
  for try await chunk in try await provider.read(RemotePath("/a (2).txt"), range: 0..<2) {
    bytes.append(chunk)
  }
  #expect(bytes == Data([1, 2]))
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.write(RemotePath("/a (2).txt"), from: url)
  }
  // 上传前重新列了目录，顺序变了对应关系也不变
  try await provider.remove(RemotePath("/a (2).txt"), recursive: false)
  let requests = await http.files()
  let download = try #require(requests.first { $0.url!.path.hasSuffix("/file/download") })
  #expect(try body(download)["fids"] as? [String] == ["f2"])
  #expect(try body(try #require(requests.last))["filelist"] as? [String] == ["f2"])
  #expect(await http.replies.isEmpty)
}

@Test func quarkDuplicateMovedOutKeepsItsShownName() async throws {
  let (provider, http) = try setup([
    list([file("f1", "a.txt"), file("f2", "a.txt"), file("dest", "dir", folder: true)]),
    list([]), Reply("/file/move"), Reply("/file/rename"),
  ])
  try await provider.connect()
  try await provider.move(RemotePath("/a (2).txt"), to: RemotePath("/dir/a (2).txt"))
  let requests = await http.files()
  #expect(requests.map { $0.url!.lastPathComponent } == ["sort", "sort", "move", "rename"])
  #expect(try body(requests[2])["filelist"] as? [String] == ["f2"])
  #expect(try body(requests[3])["fid"] as? String == "f2")
  #expect(try body(requests[3])["file_name"] as? String == "a (2).txt")
}

@Test func quarkRenamingDuplicateToItsSiblingNameConflicts() async throws {
  let (provider, http) = try setup([
    list([file("f1", "a.txt"), file("f2", "a.txt")]),
    list([file("f1", "a.txt"), file("f2", "a.txt")]),
  ])
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.move(RemotePath("/a (2).txt"), to: RemotePath("/a.txt"))
  }
  #expect(await http.files().allSatisfy { $0.httpMethod == "GET" })
}

// Finder 多选删除同名文件：删掉第一个后剩下的不重新编号，第二次删的仍是选中的那个
@Test func quarkDeletingDuplicatesOneByOneHitsTheSelectedFiles() async throws {
  let (provider, http) = try setup([
    list([file("f1", "a.txt"), file("f2", "a.txt"), file("f3", "a.txt")]),
    Reply("/file/delete"),
    list([file("f2", "a.txt"), file("f3", "a.txt")]),
    Reply("/file/delete"),
  ])
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(Set(items.map(\.path.value)) == ["/a.txt", "/a (2).txt", "/a (3).txt"])
  try await provider.remove(RemotePath("/a.txt"), recursive: false)
  try await provider.remove(RemotePath("/a (2).txt"), recursive: false)
  let deletions = await http.files().filter { $0.url!.path.hasSuffix("/file/delete") }
  #expect(try deletions.map { try body($0)["filelist"] as? [String] } == [["f1"], ["f2"]])
  #expect(await http.replies.isEmpty)
}
