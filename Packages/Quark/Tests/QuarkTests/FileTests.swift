import Core
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Quark

private final class FileSecrets: SecretStore, Sendable {
  private let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}
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
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.write(RemotePath("/new"), from: url)
  }
  #expect(await http.files().allSatisfy { !$0.url!.path.hasSuffix("/finish") })
}
@Test func quarkMkdirRenameAndTrashInvalidatePaths() async throws {
  let (provider, http) = try setup([
    list([]), Reply("/file"), list([file("f", "x")]), list([file("f", "x")]), Reply("/file/rename"),
    list([file("f", "y")]), list([file("f", "y")]), Reply("/file/delete"),
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
