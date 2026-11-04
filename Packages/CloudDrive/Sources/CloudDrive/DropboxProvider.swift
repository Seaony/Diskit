import Core
import Foundation

public actor DropboxProvider: RemoteFileProvider, OAuthProfileProviding {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private let uploadSessionThreshold: Int64
  private let chunkSize: Int64
  private var connected = false
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: OAuthSession, uploadSessionThreshold: Int64 = 150 * 1024 * 1024,
    chunkSize: Int64 = 8 * 1024 * 1024
  ) {
    self.session = session
    self.uploadSessionThreshold = uploadSessionThreshold
    self.chunkSize = chunkSize
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    let response = try await session.authorized(
      apiRequest(
        url: "https://api.dropboxapi.com/2/users/get_current_account", body: Data("null".utf8)))
    try check(response)
    connected = true
  }

  public func disconnect() async { connected = false }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/users/get_space_usage", body: Data("null".utf8))
    request.httpMethod = "POST"
    let response = try await session.authorized(request)
    try check(response)
    let value = try JSONDecoder().decode(DropboxSpace.self, from: response.body)
    return SpaceInfo(total: value.allocation.allocated, used: value.used)
  }

  public func profile() async throws -> OAuthProfile {
    let response = try await session.authorized(
      apiRequest(
        url: "https://api.dropboxapi.com/2/users/get_current_account",
        body: Data("null".utf8)))
    try check(response)
    let value = try JSONDecoder().decode(DropboxProfile.self, from: response.body)
    return OAuthProfile(
      userID: value.accountID, nickname: value.name.displayName,
      avatarURL: value.profilePhotoURL)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/files/list_folder",
      json: [
        "path": dropboxPath(path), "recursive": false, "include_deleted": false,
        "include_non_downloadable_files": false,
      ])
    request.httpMethod = "POST"
    var response = try await session.authorized(request)
    try check(response)
    var page = try JSONDecoder().decode(DropboxList.self, from: response.body)
    var entries = page.entries
    while page.hasMore {
      var next = apiRequest(
        url: "https://api.dropboxapi.com/2/files/list_folder/continue",
        json: ["cursor": page.cursor])
      next.httpMethod = "POST"
      response = try await session.authorized(next)
      try check(response)
      page = try JSONDecoder().decode(DropboxList.self, from: response.body)
      entries.append(contentsOf: page.entries)
    }
    return try entries.map { try $0.item(parent: path) }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/files/get_metadata",
      json: ["path": dropboxPath(path), "include_deleted": false])
    request.httpMethod = "POST"
    let response = try await session.authorized(request)
    try check(response)
    return try JSONDecoder().decode(DropboxEntry.self, from: response.body)
      .item(parent: parent(path))
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    var request = contentRequest(
      endpoint: "https://content.dropboxapi.com/2/files/download",
      argument: ["path": dropboxPath(path)])
    request.httpMethod = "POST"
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= range.upperBound else {
        throw RemoteError.posix(EINVAL)
      }
      if range.isEmpty { return CloudDriveSupport.emptyStream() }
      request.setValue(
        "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
        forHTTPHeaderField: "Range")
    }
    let stream = try await session.authorizedStream(request)
    if range != nil {
      guard stream.response.status == 206 else {
        if (200..<300).contains(stream.response.status) {
          throw RemoteError.protocolError
        }
        try check(stream.response)
        throw RemoteError.protocolError
      }
    } else {
      try check(stream.response, allowing: [200])
    }
    return stream.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    guard let fileSize = try localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    if size <= uploadSessionThreshold {
      let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
      var request = contentRequest(
        endpoint: "https://content.dropboxapi.com/2/files/upload",
        argument: [
          "path": dropboxPath(path), "mode": "add", "autorename": false, "mute": false,
          "strict_conflict": true,
        ])
      request.httpMethod = "POST"
      request.httpBody = data
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      try check(try await session.authorized(request), allowing: [200])
      progress?(size, size)
      return
    }
    try await sessionUpload(path: path, localFile: localFile, size: size)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/files/create_folder_v2",
      json: ["path": dropboxPath(path), "autorename": false])
    request.httpMethod = "POST"
    try check(try await session.authorized(request), allowing: [200])
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    if !recursive {
      let item = try await stat(path)
      if item.isDirectory {
        let children = try await list(path)
        if !children.isEmpty { throw RemoteError.posix(ENOTEMPTY) }
      }
    }
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/files/delete_v2",
      json: ["path": dropboxPath(path)])
    request.httpMethod = "POST"
    try check(try await session.authorized(request), allowing: [200])
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    try await ensureMissing(to)
    var request = apiRequest(
      url: "https://api.dropboxapi.com/2/files/move_v2",
      json: [
        "from_path": dropboxPath(from), "to_path": dropboxPath(to), "autorename": false,
        "allow_ownership_transfer": false,
      ])
    request.httpMethod = "POST"
    try check(try await session.authorized(request), allowing: [200])
  }

  private func sessionUpload(path: RemotePath, localFile: URL, size: Int64) async throws {
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    guard let first = try handle.read(upToCount: Int(chunkSize)) else {
      throw RemoteError.posix(EIO)
    }
    var start = contentRequest(
      endpoint: "https://content.dropboxapi.com/2/files/upload_session/start",
      argument: ["close": false])
    start.httpMethod = "POST"
    start.httpBody = first
    let startResponse = try await session.authorized(start)
    try check(startResponse)
    let sessionID = try JSONDecoder().decode(DropboxSessionID.self, from: startResponse.body)
      .sessionID
    var offset = Int64(first.count)
    while offset < size {
      try Task.checkCancellation()
      guard let data = try handle.read(upToCount: Int(min(chunkSize, size - offset))) else {
        throw RemoteError.posix(EIO)
      }
      var append = contentRequest(
        endpoint: "https://content.dropboxapi.com/2/files/upload_session/append_v2",
        argument: ["cursor": ["session_id": sessionID, "offset": offset], "close": false])
      append.httpMethod = "POST"
      append.httpBody = data
      try check(try await session.authorized(append))
      offset += Int64(data.count)
      progress?(offset, size)
    }
    var finish = contentRequest(
      endpoint: "https://content.dropboxapi.com/2/files/upload_session/finish",
      argument: [
        "cursor": ["session_id": sessionID, "offset": offset],
        "commit": [
          "path": dropboxPath(path), "mode": "add", "autorename": false, "mute": false,
          "strict_conflict": true,
        ],
      ])
    finish.httpMethod = "POST"
    finish.httpBody = Data()
    try check(try await session.authorized(finish))
  }

  private func apiRequest(url: String, body: Data) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    return request
  }

  private func apiRequest(url: String, json: [String: Any]) -> URLRequest {
    apiRequest(url: url, body: try! JSONSerialization.data(withJSONObject: json))
  }

  private func contentRequest(endpoint: String, argument: [String: Any]) -> URLRequest {
    var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 60)
    let data = try! JSONSerialization.data(withJSONObject: argument)
    // 请求头只保留 ASCII，表情按 UTF-16 代理对转义，避免文件名损坏。
    let header = String(decoding: data, as: UTF8.self).utf16.map { unit in
      unit < 127 ? String(UnicodeScalar(unit)!) : String(format: "\\u%04x", unit)
    }.joined()
    request.setValue(header, forHTTPHeaderField: "Dropbox-API-Arg")
    return request
  }

  private func dropboxPath(_ path: RemotePath) -> String { path.value == "/" ? "" : path.value }
  private func parent(_ path: RemotePath) -> RemotePath {
    let parts = path.value.split(separator: "/").dropLast()
    return try! RemotePath(parts.isEmpty ? "/" : "/" + parts.joined(separator: "/"))
  }
  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func ensureMissing(_ path: RemotePath) async throws {
    do {
      _ = try await stat(path)
      throw RemoteError.posix(EEXIST)
    } catch {
      guard CloudDriveSupport.isExplicitlyMissing(error) else { throw error }
    }
  }

  private func check(_ response: HTTPResponse, allowing: Set<Int> = [200]) throws {
    if allowing.contains(response.status) { return }
    if response.status == 401 { throw OAuthDriveError.loginRequired }
    if response.status == 409,
      let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let tag = error[".tag"] as? String,
      ["path", "from_lookup", "to_lookup"].contains(tag),
      let lookup = error[tag] as? [String: Any], lookup[".tag"] as? String == "not_found"
    {
      throw RemoteError.posix(ENOENT)
    }
    throw CloudDriveSupport.mapHTTP(response) ?? OAuthDriveError.invalidResponse
  }
}

private struct DropboxSpace: Decodable {
  struct Allocation: Decodable {
    let allocated: Int64
    enum CodingKeys: String, CodingKey { case allocated = ".tag" }
    init(from decoder: Decoder) throws {
      let object = try decoder.container(keyedBy: DynamicCodingKey.self)
      if let allocated = try object.decodeIfPresent(
        Int64.self, forKey: DynamicCodingKey("allocated"))
      {
        self.allocated = allocated
      } else {
        self.allocated = 0
      }
    }
  }
  let used: Int64
  let allocation: Allocation
}

private struct DropboxProfile: Decodable {
  struct Name: Decodable {
    let displayName: String
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
  }
  let accountID: String
  let name: Name
  let profilePhotoURL: String?
  enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case name
    case profilePhotoURL = "profile_photo_url"
  }
}

private struct DropboxList: Decodable {
  let entries: [DropboxEntry]
  let cursor: String
  let hasMore: Bool
  enum CodingKeys: String, CodingKey {
    case entries, cursor
    case hasMore = "has_more"
  }
}

private struct DropboxEntry: Decodable {
  let tag: String
  let name: String
  let pathDisplay: String?
  let size: Int64?
  let serverModified: String?
  enum CodingKeys: String, CodingKey {
    case name, size
    case tag = ".tag"
    case pathDisplay = "path_display"
    case serverModified = "server_modified"
  }
  func item(parent: RemotePath) throws -> RemoteItem {
    guard tag == "file" || tag == "folder" else { throw RemoteError.unsupported }
    let date =
      serverModified.flatMap(ISO8601DateFormatter().date)
      ?? Date(timeIntervalSince1970: 0)
    return RemoteItem(
      path: try parent.appending(name), name: name, isDirectory: tag == "folder",
      size: tag == "file" ? size ?? 0 : 0, modified: date)
  }
}

private struct DropboxSessionID: Decodable {
  let sessionID: String
  enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

private struct DynamicCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) {
    self.intValue = intValue
    stringValue = String(intValue)
  }
}
