import Core
import CryptoKit
import Foundation

public actor Drive123Provider: RemoteFileProvider, OAuthProfileProviding {
  static let maximumFileSize: Int64 = 10_000_000_000

  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private let completionTimeout: Duration
  private let completionDeadline: HTTPProgressDeadline?
  private var connected = false
  private var ids: [String: Int64] = ["/": 0]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: OAuthSession, transport: any HTTPTransport = URLSessionHTTPTransport(),
    completionPollLimit: Int = Int(RemoteTimeout.transferIdle)
  ) {
    self.init(
      session: session, transport: transport, completionPollLimit: completionPollLimit,
      completionDeadline: nil)
  }

  init(
    session: OAuthSession, transport: any HTTPTransport, completionPollLimit: Int,
    completionDeadline: HTTPProgressDeadline?
  ) {
    self.session = session
    self.transport = session.limited(transport)
    self.completionTimeout = .seconds(max(0, completionPollLimit))
    self.completionDeadline = completionDeadline
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    let value: Drive123User = try await api("GET", "/api/v1/user/info")
    _ = value
    connected = true
  }

  public func disconnect() async {
    connected = false
    ids = ["/": 0]
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let user: Drive123User = try await api("GET", "/api/v1/user/info")
    return SpaceInfo(
      total: user.spacePermanent + user.spaceTemp, used: user.spaceUsed)
  }

  public func profile() async throws -> OAuthProfile {
    let user: Drive123User = try await api("GET", "/api/v1/user/info")
    return OAuthProfile(
      userID: String(user.uid), nickname: user.nickname, avatarURL: user.headImage)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    let parent = try await resolve(path)
    var last: Int64?
    var result: [RemoteItem] = []
    var ambiguousPaths: Set<String> = []
    repeat {
      var query = [
        URLQueryItem(name: "parentFileId", value: String(parent)),
        URLQueryItem(name: "limit", value: "100"),
      ]
      if let last { query.append(URLQueryItem(name: "lastFileId", value: String(last))) }
      let page: Drive123ListData = try await api("GET", "/api/v2/file/list", query: query)
      for entry in page.fileList where entry.trashed == 0 {
        let item = try entry.item(parent: path)
        result.append(item)
        guard !ambiguousPaths.contains(item.path.value) else { continue }
        if let cached = ids[item.path.value], cached != entry.fileID {
          ids.removeValue(forKey: item.path.value)
          ambiguousPaths.insert(item.path.value)
        } else {
          ids[item.path.value] = entry.fileID
        }
      }
      last = page.lastFileID == -1 ? nil : page.lastFileID
    } while last != nil
    return result
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0))
    }
    let id = try await resolve(path)
    let value: Drive123Item = try await api(
      "GET", "/api/v1/file/detail",
      query: [URLQueryItem(name: "fileID", value: String(id))])
    return try value.item(path: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    if let range, range.lowerBound < 0 || range.lowerBound > range.upperBound {
      throw RemoteError.posix(EINVAL)
    }
    if range?.isEmpty == true { return CloudDriveSupport.emptyStream() }
    let id = try await resolve(path)
    let value: Drive123Download = try await api(
      "GET", "/api/v1/file/download_info",
      query: [URLQueryItem(name: "fileId", value: String(id))])
    guard let url = URL(string: value.downloadURL) else {
      throw RemoteError.protocolError
    }
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
        forHTTPHeaderField: "Range")
    }
    let response = try await CloudDriveSupport.streamWithRetry(transport, request)
    if let error = CloudDriveSupport.mapHTTP(response.response) { throw error }
    if range != nil, response.response.status != 206 { throw RemoteError.protocolError }
    return response.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    try await ensureMissing(path)
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    try Self.validateFileSize(size)
    let parent = try await resolve(CloudDriveSupport.parent(path))
    let etag = try hashFile(localFile)
    let created: Drive123Created = try await api(
      "POST", "/upload/v2/file/create",
      json: [
        "parentFileID": parent, "filename": CloudDriveSupport.basename(path),
        "etag": etag, "size": size,
      ])
    if created.reuse { return }
    guard let preuploadID = created.preuploadID, !preuploadID.isEmpty,
      let sliceSize = created.sliceSize, sliceSize > 0,
      let server = created.servers?.first, let base = URL(string: server),
      base.scheme == "https", base.host != nil, base.user == nil, base.password == nil
    else { throw RemoteError.protocolError }
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    var offset: Int64 = 0
    var slice = 1
    while offset < size {
      try Task.checkCancellation()
      try handle.seek(toOffset: UInt64(offset))
      let length = min(sliceSize, size - offset)
      guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
        throw RemoteError.posix(EIO)
      }
      var form = MultipartFormData()
      form.addText("preuploadID", preuploadID)
      form.addText("sliceNo", String(slice))
      form.addText("sliceMD5", CloudDriveSupport.md5Hex(data))
      form.addFile("slice", filename: "slice-\(slice)", data: data)
      let request = CloudDriveSupport.multipartRequest(
        try appendPath(base, "/upload/v2/file/slice"), form: form,
        headers: try await authenticationHeaders())
      let _: EmptyResponse = try decode(
        EmptyResponse.self, from: try await send(request, upload: true))
      offset += Int64(data.count)
      slice += 1
      progress?(offset, size)
    }
    do {
      try await (completionDeadline ?? HTTPProgressDeadline(interval: completionTimeout)).run {
        [self] in
        while true {
          try Task.checkCancellation()
          let completed: Drive123Completed = try await self.api(
            "POST", "/upload/v2/file/upload_complete", json: ["preuploadID": preuploadID])
          if completed.completed, completed.fileID != 0 { return }
          try await Task.sleep(for: .seconds(1))
        }
      }
    } catch let error as URLError where error.code == .timedOut {
      throw RemoteError.posix(ETIMEDOUT)
    }
    invalidate(from: CloudDriveSupport.parent(path))
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
    let parent = try await resolve(CloudDriveSupport.parent(path))
    let _: Drive123Directory = try await api(
      "POST", "/upload/v1/file/mkdir",
      json: ["name": CloudDriveSupport.basename(path), "parentID": parent])
    invalidate(from: CloudDriveSupport.parent(path))
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let item = try await stat(path)
    if !recursive, item.isDirectory, try await !list(path).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    let id = try await resolve(path)
    let _: EmptyResponse = try await api(
      "POST", "/api/v1/file/trash", json: ["fileIDs": [id]])
    invalidate(from: path)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    try await ensureMissing(to)
    let source = try await resolve(from)
    let parent = try await resolve(CloudDriveSupport.parent(to))
    do {
      if CloudDriveSupport.parent(from) != CloudDriveSupport.parent(to) {
        let _: EmptyResponse = try await api(
          "POST", "/api/v1/file/move",
          json: ["fileIDs": [source], "toParentFileID": parent])
      }
      if CloudDriveSupport.basename(from) != CloudDriveSupport.basename(to) {
        let _: EmptyResponse = try await api(
          "PUT", "/api/v1/file/name",
          json: ["fileId": source, "fileName": CloudDriveSupport.basename(to)])
      }
    } catch {
      invalidate(from: from)
      invalidate(from: CloudDriveSupport.parent(to))
      throw error
    }
    invalidate(from: from)
    invalidate(from: CloudDriveSupport.parent(to))
    ids[to.value] = source
  }

  private func resolve(_ path: RemotePath) async throws -> Int64 {
    if let value = ids[path.value] { return value }
    var currentPath = try RemotePath("/")
    var currentID: Int64 = 0
    for component in path.value.split(separator: "/") {
      let next = try currentPath.appending(String(component))
      if let cached = ids[next.value] {
        currentPath = next
        currentID = cached
        continue
      }
      var last: Int64?
      var found: Drive123File?
      repeat {
        var query = [
          URLQueryItem(name: "parentFileId", value: String(currentID)),
          URLQueryItem(name: "limit", value: "100"),
        ]
        if let last { query.append(URLQueryItem(name: "lastFileId", value: String(last))) }
        let page: Drive123ListData = try await api("GET", "/api/v2/file/list", query: query)
        let matches = page.fileList.filter {
          $0.filename == String(component) && $0.trashed == 0
        }
        if let value = matches.first {
          if found != nil || matches.count > 1 { throw RemoteError.posix(EEXIST) }
          found = value
        }
        last = page.lastFileID == -1 ? nil : page.lastFileID
      } while last != nil
      guard let found else { throw RemoteError.posix(ENOENT) }
      currentID = found.fileID
      currentPath = next
      ids[next.value] = currentID
    }
    return currentID
  }

  private func api<Value: Decodable>(
    _ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil
  ) async throws -> Value {
    let url = try CloudDriveSupport.url("https://open-api.123pan.com" + path, query: query)
    let request = try CloudDriveSupport.jsonRequest(
      url, method: method, json: json, headers: try await authenticationHeaders())
    let response = try await send(request)
    return try decode(Value.self, from: response)
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type, from response: HTTPResponse
  ) throws -> Value {
    do {
      if let error = CloudDriveSupport.mapHTTP(response) { throw error }
      let envelope: CloudJSONEnvelope<Value>
      do {
        envelope = try JSONDecoder().decode(CloudJSONEnvelope<Value>.self, from: response.body)
      } catch {
        throw RemoteError.protocolError
      }
      if envelope.code != 0 { throw businessError(envelope.code) }
      if Value.self == EmptyResponse.self, envelope.data == nil {
        return EmptyResponse() as! Value
      }
      guard let data = envelope.data else { throw RemoteError.protocolError }
      return data
    } catch {
      if (200..<300).contains(response.status) {
        PackageDiagnostics.failure(error, category: .cloudDrive, operation: .request)
      }
      throw error
    }
  }

  private func send(_ request: URLRequest, upload: Bool = false) async throws -> HTTPResponse {
    let first = try await CloudDriveSupport.sendWithRetry(transport, request, upload: upload)
    guard first.status == 401 || businessCode(in: first) == 401 else { return first }
    var retry = request
    retry.setValue(
      "Bearer \(try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request)))",
      forHTTPHeaderField: "Authorization")
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry, upload: upload)
    if second.status == 401 || businessCode(in: second) == 401 {
      throw OAuthDriveError.loginRequired
    }
    return second
  }

  private func businessCode(in response: HTTPResponse) -> Int? {
    guard (200..<300).contains(response.status),
      let value = try? JSONDecoder().decode(CloudJSONCodeEnvelope.self, from: response.body)
    else { return nil }
    return value.code
  }

  private func authenticationHeaders() async throws -> [String: String] {
    [
      "Authorization": "Bearer \(try await session.accessToken())",
      "Platform": "open_platform",
    ]
  }

  private func appendPath(_ base: URL, _ path: String) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw RemoteError.protocolError
    }
    components.path = path
    guard let url = components.url else { throw RemoteError.protocolError }
    return url
  }

  private func invalidate(from path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    ids = ids.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    ids["/"] = 0
  }

  private func hashFile(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func businessError(_ code: Int?) -> RemoteError {
    switch code {
    case 401:
      return .unauthorized
    case 429, 5113:
      return .rateLimited
    case 5060:
      return .posix(EEXIST)
    case 5066:
      return .posix(ENOENT)
    default:
      return .protocolError
    }
  }

  static func validateFileSize(_ size: Int64) throws {
    guard size >= 0, size <= maximumFileSize else {
      throw RemoteError.posix(EFBIG)
    }
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }
}

private struct EmptyResponse: Decodable {}

private struct CloudJSONCodeEnvelope: Decodable {
  let code: Int?
}

private struct Drive123User: Decodable {
  let uid: Int64
  let nickname: String
  let headImage: String
  let spaceUsed: Int64
  let spacePermanent: Int64
  let spaceTemp: Int64
}

private struct Drive123ListData: Decodable {
  let lastFileID: Int64
  let fileList: [Drive123File]
  enum CodingKeys: String, CodingKey {
    case lastFileID = "lastFileId"
    case fileList
  }
}

private struct Drive123File: Decodable {
  let fileID: Int64
  let filename: String
  let type: Int
  let size: Int64
  let parentFileID: Int64
  let trashed: Int
  let updateAt: String?
  enum CodingKeys: String, CodingKey {
    case fileID = "fileId"
    case filename, type, size, trashed, updateAt
    case parentFileID = "parentFileId"
  }
  func item(parent: RemotePath) throws -> RemoteItem {
    RemoteItem(
      path: try parent.appending(filename), name: filename, isDirectory: type == 1, size: size,
      modified: CloudDriveSupport.parseDate(updateAt))
  }
}

private struct Drive123Item: Decodable {
  let fileID: Int64
  let filename: String
  let type: Int
  let size: Int64
  let parentFileID: Int64
  let trashed: Int
  let updateAt: String?
  enum CodingKeys: String, CodingKey {
    case fileID = "fileID"
    case filename, type, size, trashed, updateAt
    case parentFileID = "parentFileID"
  }
  func item(path: RemotePath) throws -> RemoteItem {
    RemoteItem(
      path: path, name: filename, isDirectory: type == 1, size: size,
      modified: CloudDriveSupport.parseDate(updateAt))
  }
}

private struct Drive123Download: Decodable {
  let downloadURL: String
  enum CodingKeys: String, CodingKey { case downloadURL = "downloadUrl" }
}

private struct Drive123Created: Decodable {
  let fileID: Int64
  let reuse: Bool
  let preuploadID: String?
  let sliceSize: Int64?
  let servers: [String]?
  enum CodingKeys: String, CodingKey {
    case fileID, reuse, preuploadID, sliceSize, servers
  }
}

private struct Drive123Completed: Decodable {
  let completed: Bool
  let fileID: Int64
}

private struct Drive123Directory: Decodable {
  let dirID: Int64
}
