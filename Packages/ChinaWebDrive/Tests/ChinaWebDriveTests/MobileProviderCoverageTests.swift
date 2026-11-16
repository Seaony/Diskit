import Core
import Foundation
import Testing

@testable import ChinaWebDrive

private actor MobileCoverageHTTP: HTTPTransport {
  var replies: [HTTPResponse]
  var streams: [HTTPResponse]
  private(set) var paths: [String] = []
  init(_ replies: [HTTPResponse], streams: [HTTPResponse] = []) {
    self.replies = replies
    self.streams = streams
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    paths.append(request.url?.path ?? "")
    guard !replies.isEmpty else { throw RemoteError.protocolError }
    return replies.removeFirst()
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    guard !streams.isEmpty else { throw RemoteError.protocolError }
    let response = streams.removeFirst()
    return HTTPStreamResponse(response: response, body: AsyncThrowingStream { $0.finish() })
  }
}

private func coverageReply(_ value: String) -> HTTPResponse {
  HTTPResponse(status: 200, body: Data(value.utf8))
}
private let coverageRoute = coverageReply(
  #"{"success":true,"data":{"routePolicyList":[{"modName":"personal","httpsUrl":"https://personal-kd-njs.yun.139.com/hcy","hashName":"sha256"}]}}"#
)
private let coverageEmpty = coverageReply(#"{"success":true,"data":{"items":[]}}"#)
private let coverageFile = coverageReply(
  #"{"success":true,"data":{"items":[{"fileId":"f","name":"file","type":"file","size":4}]}}"#)
private func coverageProvider(_ http: MobileCoverageHTTP) -> MobileCloudProvider {
  MobileCloudProvider(
    session: MobileCloudSession(
      credentials: MobileCloudCredentials(phone: "local", token: "token"), transport: http))
}

@Test(arguments: [
  "empty-id", "renamed", "missing-upload", "missing-parts", "wrong-count", "wrong-size",
  "unsafe-url",
])
func mobileUploadRejectsInvalidCreatedObjectAndCleansOnlyOwnedObject(problem: String) async throws {
  var created: [String: Any] = ["fileId": "new", "fileName": "file", "uploadId": "upload"]
  switch problem {
  case "empty-id": created["fileId"] = ""
  case "renamed": created["fileName"] = "file (1)"
  case "missing-upload": created.removeValue(forKey: "uploadId")
  case "wrong-count": created["partInfos"] = []
  case "wrong-size":
    created["partInfos"] = [
      ["partNumber": 1, "partSize": 3, "uploadUrl": "https://upload.example/part"]
    ]
  case "unsafe-url":
    created["partInfos"] = [
      ["partNumber": 1, "partSize": 4, "uploadUrl": "http://upload.example/part"]
    ]
  default: break
  }
  let reply = HTTPResponse(
    status: 200,
    body: try JSONSerialization.data(withJSONObject: ["success": true, "data": created]))
  let http = MobileCoverageHTTP([
    coverageRoute, coverageEmpty, reply, coverageReply(#"{"success":true,"data":{}}"#),
  ])
  let provider = coverageProvider(http)
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("data".utf8).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  if problem == "renamed" {
    await #expect(throws: RemoteError.posix(EEXIST)) {
      try await provider.write(RemotePath("/file"), from: file)
    }
  } else {
    await #expect(throws: MobileCloudError.invalidResponse) {
      try await provider.write(RemotePath("/file"), from: file)
    }
  }
  let paths = await http.paths
  #expect(paths.contains { $0.hasSuffix("recyclebin/batchTrash") } == (problem != "empty-id"))
  #expect(!paths.contains { $0.hasSuffix("file/complete") })
}

@Test(arguments: ["empty-id", "existing", "renamed"])
func mobileDirectoryCreateValidatesIdentityAndDoesNotDeleteExistingObject(problem: String)
  async throws
{
  let id = problem == "empty-id" ? "" : "new"
  let name = problem == "renamed" ? "folder (1)" : "folder"
  let reply = HTTPResponse(
    status: 200,
    body: try JSONSerialization.data(withJSONObject: [
      "success": true, "data": ["fileId": id, "fileName": name, "exist": problem == "existing"],
    ]))
  let http = MobileCoverageHTTP([
    coverageRoute, coverageEmpty, reply, coverageReply(#"{"success":true,"data":{}}"#),
  ])
  let provider = coverageProvider(http)
  try await provider.connect()
  if problem == "empty-id" {
    await #expect(throws: MobileCloudError.invalidResponse) {
      try await provider.makeDirectory(RemotePath("/folder"))
    }
  } else {
    await #expect(throws: RemoteError.posix(EEXIST)) {
      try await provider.makeDirectory(RemotePath("/folder"))
    }
  }
  let paths = await http.paths
  #expect(paths.contains { $0.hasSuffix("recyclebin/batchTrash") } == (problem == "renamed"))
}

@Test func mobileRootAndFileTraversalKeepPOSIXSemantics() async throws {
  let http = MobileCoverageHTTP([coverageRoute, coverageFile, coverageFile])
  let provider = coverageProvider(http)
  try await provider.connect()
  #expect(try await provider.stat(RemotePath("/")).isDirectory)
  try await provider.makeDirectory(RemotePath("/"))
  await #expect(throws: RemoteError.posix(ENOTDIR)) {
    _ = try await provider.list(RemotePath("/file"))
  }
  await #expect(throws: RemoteError.posix(ENOTDIR)) {
    _ = try await provider.stat(RemotePath("/file/child"))
  }
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await provider.remove(RemotePath("/"), recursive: true)
  }
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await provider.move(RemotePath("/"), to: RemotePath("/new"))
  }
  await provider.disconnect()
  await #expect(throws: RemoteError.notConnected) { _ = try await provider.stat(RemotePath("/")) }
}

@Test(arguments: [false, true])
func mobileDownloadRejectsWrongFullResponseAndRetriesExpiredLink(ranged: Bool) async throws {
  let link = coverageReply(#"{"success":true,"data":{"url":"https://download.example/file"}}"#)
  let http = MobileCoverageHTTP(
    [coverageRoute, coverageFile, link, link],
    streams: [
      HTTPResponse(status: 403), HTTPResponse(status: ranged ? 200 : 206),
    ])
  let provider = coverageProvider(http)
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    _ = try await provider.read(RemotePath("/file"), range: ranged ? 0..<2 : nil)
  }
  let paths = await http.paths
  #expect(paths.filter { $0.hasSuffix("file/getDownloadUrl") }.count == 2)
}

@Test func mobileEmptyRangeDoesNotRequestDownloadURL() async throws {
  let http = MobileCoverageHTTP([coverageRoute, coverageFile])
  let provider = coverageProvider(http)
  try await provider.connect()
  var bytes = 0
  for try await data in try await provider.read(RemotePath("/file"), range: 4..<4) {
    bytes += data.count
  }
  #expect(bytes == 0)
  let paths = await http.paths
  #expect(!paths.contains { $0.hasSuffix("file/getDownloadUrl") })
}

@Test func mobileSplitRejectsInvalidSizesAndExcessiveParts() throws {
  #expect(throws: RemoteError.protocolError) {
    try MobileCloudProvider.splitForTesting(size: -1, partSize: 1)
  }
  #expect(throws: RemoteError.protocolError) {
    try MobileCloudProvider.splitForTesting(size: 1, partSize: 0)
  }
  #expect(throws: RemoteError.posix(EFBIG)) {
    try MobileCloudProvider.splitForTesting(size: 10_001, partSize: 1)
  }
}

@Test(arguments: ["negative", "free-over-total", "malformed"])
func mobileCapacityRejectsInconsistentOrMalformedValues(problem: String) async throws {
  let body: String
  switch problem {
  case "negative": body = #"{"success":true,"data":{"diskSize":-1,"usedSize":0}}"#
  case "free-over-total": body = #"{"success":true,"data":{"diskSize":4,"freeDiskSize":5}}"#
  default: body = #"{"success":true,"data":[]}"#
  }
  let provider = coverageProvider(MobileCoverageHTTP([coverageRoute, coverageReply(body)]))
  try await provider.connect()
  await #expect(throws: MobileCloudError.invalidResponse) { _ = try await provider.spaceInfo() }
}

@Test(arguments: ["negative-size", "unknown-type"])
func mobileListingRejectsInvalidRemoteMetadata(problem: String) async throws {
  let reply = HTTPResponse(
    status: 200,
    body: try JSONSerialization.data(withJSONObject: [
      "success": true,
      "data": [
        "items": [
          [
            "fileId": "f", "name": "file", "size": problem == "negative-size" ? -1 : 1,
            "type": problem == "unknown-type" ? "unknown" : "file",
          ]
        ]
      ],
    ]))
  let provider = coverageProvider(MobileCoverageHTTP([coverageRoute, reply]))
  try await provider.connect()
  await #expect(throws: MobileCloudError.invalidResponse) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test func mobileDownloadLinkIsReusedUntilRejectedOrFileChanges() async throws {
  let link = coverageReply(#"{"success":true,"data":{"url":"https://download.example/file"}}"#)
  let resized = coverageReply(
    #"{"success":true,"data":{"items":[{"fileId":"f","name":"file","type":"file","size":5}]}}"#)
  let ok = HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-1/4"])
  let http = MobileCoverageHTTP(
    [coverageRoute, coverageFile, link, link, resized, link],
    streams: [
      ok, ok, HTTPResponse(status: 403), ok,
      HTTPResponse(status: 206, headers: ["Content-Range": "bytes 0-1/5"]),
    ])
  let provider = coverageProvider(http)
  try await provider.connect()
  func linkRequests() async -> Int {
    await http.paths.filter { $0.hasSuffix("file/getDownloadUrl") }.count
  }
  _ = try await provider.read(RemotePath("/file"), range: 0..<2)
  _ = try await provider.read(RemotePath("/file"), range: 0..<2)
  #expect(await linkRequests() == 1)
  _ = try await provider.read(RemotePath("/file"), range: 0..<2)
  #expect(await linkRequests() == 2)
  _ = try await provider.list(RemotePath("/"))
  _ = try await provider.read(RemotePath("/file"), range: 0..<2)
  #expect(await linkRequests() == 3)
}
