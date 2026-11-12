import Core
import Foundation
import Testing

@testable import CloudDrive

private actor InternationalAuditHTTP: HTTPTransport {
  let reply: @Sendable (URLRequest) throws -> HTTPResponse
  var requests: [URLRequest] = []
  init(_ reply: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.reply = reply }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try reply(request)
  }
}

private func auditJSON(_ object: Any, status: Int = 200) throws -> HTTPResponse {
  HTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
}

private func auditSession(_ http: any HTTPTransport) throws -> OAuthSession {
  let store = MemorySecretStore()
  try store.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "local", refreshToken: "local", expiresAt: .distantFuture)),
    for: "account")
  return OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "local", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/auth")!,
      tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://test",
      scopes: []), secretKey: "account", secrets: store, transport: http)
}

private func auditGoogleFile(_ id: String, _ name: String) -> [String: String] {
  ["id": id, "name": name, "mimeType": "text/plain", "size": "1"]
}

@Test func googleListingPreservesEveryUnusualNameWithStableIdentity() async throws {
  let files = [
    auditGoogleFile("one", "same"), auditGoogleFile("two", "same"), auditGoogleFile("slash", "a/b"),
    auditGoogleFile("reserved", "~diskit~b25l"), auditGoogleFile("ordinary", "normal"),
  ]
  let http = InternationalAuditHTTP { request in
    guard request.url?.host == "www.googleapis.com" else { return HTTPResponse(status: 404) }
    let path = request.url!.path
    if path == "/drive/v3/about" { return try auditJSON(["user": [:]]) }
    if path == "/drive/v3/files" { return try auditJSON(["files": files]) }
    if let file = files.first(where: { path == "/drive/v3/files/" + $0["id"]! }) {
      if request.httpMethod == "PATCH" { return HTTPResponse(status: 200) }
      return try auditJSON(file)
    }
    return HTTPResponse(status: 404)
  }
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  #expect(items.map(\.name) == files.map { $0["name"]! })
  #expect(Set(items.map(\.path)).count == files.count)
  #expect(items.last?.path.value == "/normal")
  for item in items {
    let stat = try await provider.stat(item.path)
    #expect(stat.path == item.path)
    #expect(stat.name == item.name)
  }
  try await provider.remove(items[1].path, recursive: false)
  #expect(await http.requests.last?.url?.path == "/drive/v3/files/two")
  let cold = GoogleDriveProvider(session: try auditSession(http))
  try await cold.connect()
  #expect(try await cold.stat(items[2].path).name == "a/b")
}

@Test func googleIdentityPathCannotEscapeItsListedParent() async throws {
  let http = InternationalAuditHTTP { request in
    if request.url?.path == "/drive/v3/about" { return try auditJSON(["user": [:]]) }
    guard request.url?.path == "/drive/v3/files" else {
      Issue.record("虚拟身份不应直接请求未列出的文件")
      return HTTPResponse(status: 404)
    }
    let q =
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
        $0.name == "q"
      }?.value ?? ""
    if q.contains("name = 'folder'") {
      return try auditJSON([
        "files": [
          ["id": "folder-id", "name": "folder", "mimeType": "application/vnd.google-apps.folder"]
        ]
      ])
    }
    return try auditJSON(["files": []])
  }
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.stat(RemotePath("/folder/~diskit~b3V0c2lkZQ"))
  }
}

@Test func googleSameFolderRenameOmitsParentMutationAndEncodesPlus() async throws {
  let http = InternationalAuditHTTP { request in
    if request.url?.path == "/drive/v3/about" { return try auditJSON(["user": [:]]) }
    if request.httpMethod == "PATCH" { return HTTPResponse(status: 200) }
    guard request.url?.path == "/drive/v3/files" else { return HTTPResponse(status: 404) }
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    let q = components.queryItems?.first { $0.name == "q" }?.value ?? ""
    if q.contains("a+b") {
      #expect(components.percentEncodedQuery?.contains("%2B") == true)
      #expect(components.percentEncodedQuery?.contains("+") == false)
      return try auditJSON(["files": [auditGoogleFile("source", "a+b")]])
    }
    return try auditJSON(["files": []])
  }
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  try await provider.move(RemotePath("/a+b"), to: RemotePath("/new"))
  let request = try #require(await http.requests.last)
  #expect(request.httpMethod == "PATCH")
  let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  #expect(!query.contains { ["addParents", "removeParents"].contains($0.name) })
}

private actor GoogleResumeAuditHTTP: HTTPTransport {
  var chunks: [URLRequest] = []
  let missingRange: Bool
  init(missingRange: Bool) { self.missingRange = missingRange }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path == "/drive/v3/about" { return try auditJSON(["user": [:]]) }
    if request.url?.path == "/drive/v3/files" { return try auditJSON(["files": []]) }
    if request.url?.path == "/upload/drive/v3/files" {
      return HTTPResponse(
        status: 200, headers: ["Location": "https://upload.example.invalid/session"])
    }
    guard request.url?.absoluteString == "https://upload.example.invalid/session" else {
      return HTTPResponse(status: 404)
    }
    chunks.append(request)
    if chunks.count == 1 {
      return HTTPResponse(status: 308, headers: missingRange ? [:] : ["Range": "bytes=0-1048575"])
    }
    return HTTPResponse(status: 201)
  }
}

@Test(arguments: [false, true]) func googleResumableUploadUsesAcknowledgedBytes(missingRange: Bool)
  async throws
{
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let size = 6 * 1024 * 1024
  try Data(repeating: 7, count: size).write(to: file)
  let http = GoogleResumeAuditHTTP(missingRange: missingRange)
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  try await provider.write(RemotePath("/file"), from: file)
  let chunks = await http.chunks
  #expect(chunks.count == 2)
  let offset = missingRange ? 0 : 1024 * 1024
  #expect(
    chunks[1].value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(size - 1)/\(size)")
  #expect(chunks[1].httpBody?.count == size - offset)
}

@Test(arguments: ["/target/new", "/new", "/source/new"])
func oneDriveMoveUsesParentIDAndRenameAvoidsParentChange(destination: String) async throws {
  let http = InternationalAuditHTTP { request in
    guard request.url?.host == "graph.microsoft.com" else { return HTTPResponse(status: 404) }
    if request.httpMethod == "PATCH" { return HTTPResponse(status: 200) }
    if request.url?.path == "/v1.0/me/drive/root" {
      return try auditJSON(["id": "actual-root", "name": "root", "folder": [:]])
    }
    if request.url?.path == "/v1.0/me/drive/root:/target" {
      return try auditJSON(["id": "target-id", "name": "target", "folder": [:]])
    }
    return HTTPResponse(status: 404)
  }
  let provider = OneDriveProvider(session: try auditSession(http), transport: http)
  try await provider.connect()
  try await provider.move(RemotePath("/source/file"), to: RemotePath(destination))
  let request = try #require(await http.requests.last)
  let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
  #expect(body["name"] as? String == "new")
  let reference = body["parentReference"] as? [String: String]
  if destination == "/source/new" {
    #expect(reference == nil)
  } else {
    #expect(reference == ["id": destination == "/new" ? "actual-root" : "target-id"])
  }
}

@Test func oneDrivePreconditionFailureIsNameConflict() async throws {
  let http = InternationalAuditHTTP { request in
    if request.url?.path == "/v1.0/me/drive/root" { return HTTPResponse(status: 200) }
    return HTTPResponse(status: request.httpMethod == "GET" ? 404 : 412)
  }
  let provider = OneDriveProvider(session: try auditSession(http), transport: http)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.makeDirectory(RemotePath("/new"))
  }
}

@Test func internationalDriveMissingQuotaIsUnknownInsteadOfZero() async throws {
  let http = InternationalAuditHTTP { request in
    switch request.url?.host {
    case "www.googleapis.com": return try auditJSON(["storageQuota": ["usage": "5"], "user": [:]])
    case "graph.microsoft.com": return try auditJSON(["quota": ["used": 5]])
    case "api.dropboxapi.com": return try auditJSON(["used": 5, "allocation": [:]])
    default: return HTTPResponse(status: 404)
    }
  }
  let providers: [any RemoteFileProvider] = [
    GoogleDriveProvider(session: try auditSession(http)),
    OneDriveProvider(session: try auditSession(http), transport: http),
    DropboxProvider(session: try auditSession(http)),
  ]
  for provider in providers {
    try await provider.connect()
    let space = try await provider.spaceInfo()
    #expect(space.total == nil)
    #expect(space.used == 5)
    #expect(space.available == nil)
  }
}

@Test func oneDriveBoundsDirectUploadMemoryEvenBelowServiceLimit() async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  FileManager.default.createFile(atPath: file.path, contents: nil)
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: 9 * 1024 * 1024)
  try handle.close()
  let http = InternationalAuditHTTP { request in
    if request.url?.path == "/v1.0/me/drive/root" { return HTTPResponse(status: 200) }
    if request.url?.host == "graph.microsoft.com" {
      if request.httpMethod == "GET" { return HTTPResponse(status: 404) }
      if request.url?.path.hasSuffix("/createUploadSession") == true {
        return try auditJSON(["uploadUrl": "https://upload.example.invalid/bounded"])
      }
    }
    if request.url?.absoluteString == "https://upload.example.invalid/bounded" {
      #expect(request.httpBody?.count == 1024 * 1024)
      let range = try #require(request.value(forHTTPHeaderField: "Content-Range"))
      if range.hasPrefix("bytes 8388608-") { return HTTPResponse(status: 201) }
      let end = try #require(Int64(range.split(separator: "-")[1].split(separator: "/")[0]))
      return try auditJSON(["nextExpectedRanges": ["\(end + 1)-"]], status: 202)
    }
    return HTTPResponse(status: 404)
  }
  let provider = OneDriveProvider(
    session: try auditSession(http), transport: http, chunkSize: 1024 * 1024)
  try await provider.connect()
  try await provider.write(RemotePath("/file"), from: file)
  #expect(await http.requests.filter { $0.url?.host == "upload.example.invalid" }.count == 9)
}

@Test func googleMovingIdentityPathKeepsOriginalRemoteName() async throws {
  let source = auditGoogleFile("slash", "a/b")
  let folder = [
    "id": "destination", "name": "Folder", "mimeType": "application/vnd.google-apps.folder",
  ]
  let http = InternationalAuditHTTP { request in
    if request.url?.path == "/drive/v3/about" { return try auditJSON(["user": [:]]) }
    if request.httpMethod == "PATCH" { return HTTPResponse(status: 200) }
    if request.url?.path == "/drive/v3/files/slash" { return try auditJSON(source) }
    if request.url?.path == "/drive/v3/files" {
      let query =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
          $0.name == "q"
        }?.value ?? ""
      if query.contains("name = 'a/b'") {
        #expect(query.contains("'destination' in parents"))
        return try auditJSON(["files": []])
      }
      return try auditJSON(["files": [source, folder]])
    }
    return HTTPResponse(status: 404)
  }
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  let from = try #require(items.first { $0.name == "a/b" }).path
  try await provider.move(from, to: RemotePath("/Folder" + from.value))
  let request = try #require(await http.requests.last)
  let body = try #require(
    JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
  #expect(body["name"] == "a/b")
  let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  #expect(query.first { $0.name == "addParents" }?.value == "destination")
  #expect(query.first { $0.name == "removeParents" }?.value == "root")
}

@Test func googleIdentityPathRemainsUsableWhenDuplicateDisappears() async throws {
  let file = auditGoogleFile("one", "same")
  let http = InternationalAuditHTTP { request in
    switch request.url?.path {
    case "/drive/v3/about": return try auditJSON(["user": [:]])
    case "/drive/v3/files": return try auditJSON(["files": [file]])
    case "/drive/v3/files/one": return try auditJSON(file)
    default: return HTTPResponse(status: 404)
    }
  }
  let provider = GoogleDriveProvider(session: try auditSession(http))
  try await provider.connect()
  let oldIdentityPath = try RemotePath("/~diskit~b25l")
  #expect(try await provider.stat(oldIdentityPath).path == oldIdentityPath)
  #expect(try await provider.list(RemotePath("/")).first?.path.value == "/same")
}
