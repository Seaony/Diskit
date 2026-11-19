import Core
import Foundation

public actor GoogleDriveProvider: RemoteFileProvider, OAuthProfileProviding {
  // 重名文件分到的编号在本次连接里保持不变
  private let duplicateNames = DuplicateNameMemory()
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  // 路径用 Finder 里显示的名字（同名文件编了号），对应到 Google 的文件 ID
  private var ids: [String: String] = ["/": "root"]
  private var mimeTypes: [String: String] = [:]
  // 文件 ID 对应网盘上的真实名字
  private var names: [String: String] = [:]
  private var connected = false
  private let chunkSize = 8 * 1024 * 1024
  private var cacheRevision: UInt64 = 0

  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public init(session: OAuthSession) { self.session = session }

  public func connect() async throws {
    let response = try await session.authorized(
      URLRequest(url: try url("/about", query: [URLQueryItem(name: "fields", value: "user")])))
    try check(response)
    connected = true
  }

  public func disconnect() async {
    connected = false
    cacheRevision &+= 1
    ids = ["/": "root"]
    mimeTypes = [:]
    names = [:]
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let response = try await session.authorized(
      URLRequest(
        url: try url("/about", query: [URLQueryItem(name: "fields", value: "storageQuota")])))
    try check(response)
    let value = try JSONDecoder().decode(GoogleAbout.self, from: response.body)
    return SpaceInfo(total: value.storageQuota.limit, used: value.storageQuota.usage)
  }

  public func profile() async throws -> OAuthProfile {
    let response = try await session.authorized(
      URLRequest(url: try url("/about", query: [URLQueryItem(name: "fields", value: "user")])))
    try check(response)
    let value = try JSONDecoder().decode(GoogleProfileEnvelope.self, from: response.body)
    return OAuthProfile(
      userID: value.user.permissionId ?? value.user.emailAddress ?? "google-drive",
      nickname: value.user.displayName ?? value.user.emailAddress ?? "Google Drive",
      avatarURL: value.user.photoLink)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    return try await entries(path).map(\.item)
  }

  private func entries(_ path: RemotePath) async throws -> [(item: RemoteItem, file: GoogleFile)] {
    let parentID = try await resolve(path)
    let revision = cacheRevision
    var pageToken: String?
    var files: [GoogleFile] = []
    repeat {
      var query = [
        URLQueryItem(name: "q", value: "'\(escaped(parentID))' in parents and trashed = false"),
        URLQueryItem(
          name: "fields",
          value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
        URLQueryItem(name: "pageSize", value: "1000"),
      ]
      if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      let response = try await session.authorized(URLRequest(url: try url("/files", query: query)))
      try check(response)
      let page = try JSONDecoder().decode(GooglePage.self, from: response.body)
      files.append(contentsOf: page.files)
      pageToken = page.nextPageToken
    } while pageToken != nil
    let display = duplicateNames.assign(
      try files.map { file in
        guard !file.id.isEmpty else { throw RemoteError.protocolError }
        return DuplicateNames.Entry(
          id: file.id, name: Self.segment(file.name), isDirectory: file.isDirectory)
      }, in: path.value)
    let result = try files.map { file in
      guard let name = display[file.id] else { throw RemoteError.protocolError }
      return (item: try file.item(at: path.appending(name)), file: file)
    }
    if cacheRevision == revision {
      let prefix = path.value == "/" ? "/" : path.value + "/"
      ids = ids.filter { !$0.key.hasPrefix(prefix) }
      mimeTypes = mimeTypes.filter { !$0.key.hasPrefix(prefix) }
      ids[path.value] = parentID
      for (item, file) in result {
        ids[item.path.value] = file.id
        mimeTypes[item.path.value] = file.mimeType
        names[file.id] = file.name
      }
    }
    return result
  }

  // 路径段里不能有 /，按 macOS 惯例换成 :（Finder 会把 : 显示成 /）；空名和 . .. 前面加 _
  static func segment(_ name: String) -> String {
    let value = name.replacingOccurrences(of: "/", with: ":")
      .replacingOccurrences(of: "\0", with: "")
    return ["", ".", ".."].contains(value) ? "_" + value : value
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    let revision = cacheRevision
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let id = try await resolve(path)
    let query = [
      URLQueryItem(name: "fields", value: "id,name,mimeType,size,modifiedTime")
    ]
    let response = try await session.authorized(
      URLRequest(url: try url("/files/\(id)", query: query)))
    try check(response)
    let file = try JSONDecoder().decode(GoogleFile.self, from: response.body)
    if cacheRevision == revision {
      mimeTypes[path.value] = file.mimeType
      names[file.id] = file.name
    }
    return file.item(at: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= range.upperBound else {
        throw RemoteError.posix(EINVAL)
      }
      if range.isEmpty { return CloudDriveSupport.emptyStream() }
    }
    let id = try await resolve(path)
    try await ensureDownloadable(path: path, id: id)
    var request = URLRequest(
      url: try url("/files/\(id)", query: [URLQueryItem(name: "alt", value: "media")]))
    if let range {
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
    let progress = self.progress
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    try await ensureNameMissing(path)
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize else {
      throw CloudDriveSupport.localFileUnreadable(localFile)
    }
    if size <= 5 * 1024 * 1024 {
      let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
      let metadata = try JSONSerialization.data(withJSONObject: [
        "name": basename(path), "parents": [try await resolve(parent(path))],
      ])
      let boundary = "diskit-" + UUID().uuidString
      var body = Data(
        "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
      body.append(metadata)
      body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
      body.append(data)
      body.append(Data("\r\n--\(boundary)--\r\n".utf8))
      var request = URLRequest(
        url: URL(
          string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
      request.httpMethod = "POST"
      request.setValue(
        "multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
      try check(try await session.authorized(request, upload: true), allowing: [200, 201])
      progress?(Int64(size), Int64(size))
    } else {
      try await resumableWrite(
        path: path, localFile: localFile, size: Int64(size), progress: progress)
    }
    invalidate(from: parent(path))
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureNameMissing(path)
    let parentID = try await resolve(parent(path))
    var request = URLRequest(url: try url("/files"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": basename(path), "mimeType": "application/vnd.google-apps.folder",
      "parents": [parentID],
    ])
    try check(try await session.authorized(request), allowing: [200, 201])
    invalidate(from: parent(path))
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let item = try await stat(path)
    if !recursive, item.isDirectory {
      let children = try await list(path)
      if !children.isEmpty { throw RemoteError.posix(ENOTEMPTY) }
    }
    let id = try await resolve(path)
    var request = URLRequest(url: try url("/files/\(id)"))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"trashed":true}"#.utf8)
    try check(try await session.authorized(request), allowing: [200])
    invalidate(from: parent(path))
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    let id = try await resolve(from)
    // 显示名是编号或替换过字符的名字时，只要目标显示名不变就保留网盘上的真实名字
    let currentName = names[id] ?? basename(from)
    let targetName = Self.segment(currentName) == basename(to) ? currentName : basename(to)
    try await ensureNameMissing(to, name: targetName)
    let oldParent = try await resolve(parent(from))
    let newParent = try await resolve(parent(to))
    var query = [URLQueryItem(name: "fields", value: "id,name,parents")]
    if oldParent != newParent {
      query += [
        URLQueryItem(name: "addParents", value: newParent),
        URLQueryItem(name: "removeParents", value: oldParent),
      ]
    }
    var request = URLRequest(url: try url("/files/\(id)", query: query))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": targetName])
    try check(try await session.authorized(request), allowing: [200])
    invalidate(from: parent(from))
    invalidate(from: parent(to))
  }

  private func resumableWrite(
    path: RemotePath, localFile: URL, size: Int64, progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    var start = URLRequest(
      url: URL(
        string:
          "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name")!)
    start.httpMethod = "POST"
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
    start.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
    start.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": basename(path), "parents": [try await resolve(parent(path))],
    ])
    var uploadURL = try await beginUploadSession(start)
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    do {
      var offset: Int64 = 0
      var recoveries = 0
      var stalled = 0
      var reported: Int64 = 0
      while offset < size {
        try Task.checkCancellation()
        let end = min(offset + Int64(chunkSize), size)
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(end - offset)) ?? Data()
        guard data.count == end - offset else {
          throw CloudDriveSupport.localShortRead(
            localFile, offset: offset, expected: end - offset, actual: data.count)
        }
        var chunk = URLRequest(url: uploadURL)
        chunk.httpMethod = "PUT"
        chunk.httpBody = data
        chunk.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        chunk.setValue("bytes \(offset)-\(end - 1)/\(size)", forHTTPHeaderField: "Content-Range")
        var response: HTTPResponse
        do {
          // 丢失响应时先查服务端位置，不能直接重放分片。
          response = try await session.authorized(chunk, upload: true, retrySafe: false)
        } catch let error as URLError where Self.recoverableUploadError(error) {
          guard recoveries < 3 else { throw error }
          recoveries += 1
          response = try await uploadStatus(uploadURL, size: size)
        }
        if (500...599).contains(response.status) {
          guard recoveries < 3 else { try check(response); throw RemoteError.protocolError }
          recoveries += 1
          response = try await uploadStatus(uploadURL, size: size)
        }
        if response.status == 404 {
          guard recoveries < 3 else { throw RemoteError.posix(ETIMEDOUT) }
          recoveries += 1
          // 最后一次响应可能丢失；重建前检查名称，保留已经完成的文件。
          try await ensureNameMissing(path)
          uploadURL = try await beginUploadSession(start)
          offset = 0
          stalled = 0
          continue
        }
        try check(response, allowing: [200, 201, 308])
        if response.status != 308 {
          guard end == size else { throw RemoteError.protocolError }
          progress?(size, size)
          return
        }
        let next: Int64
        if let range = response.header("Range") {
          guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst(8)),
            last >= 0, last < end, last < size - 1
          else { throw RemoteError.protocolError }
          next = last + 1
        } else {
          next = 0
        }
        guard next >= offset else { throw RemoteError.protocolError }
        if next > offset {
          reported = max(reported, next)
          progress?(reported, size)
          stalled = 0
        } else {
          stalled += 1
          guard stalled <= 3 else { throw RemoteError.posix(ETIMEDOUT) }
        }
        offset = next
      }
    } catch {
      await cancelUploadSession(uploadURL)
      throw error
    }
  }

  private func beginUploadSession(_ request: URLRequest) async throws -> URL {
    let started = try await session.authorized(request, retrySafe: false)
    try check(started, allowing: [200])
    guard let location = started.header("Location"), let url = URL(string: location),
      url.scheme == "https"
    else { throw RemoteError.protocolError }
    return url
  }

  private func uploadStatus(_ url: URL, size: Int64) async throws -> HTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.httpBody = Data()
    request.setValue("0", forHTTPHeaderField: "Content-Length")
    request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
    return try await session.authorized(request, retrySafe: false)
  }

  private static func recoverableUploadError(_ error: URLError) -> Bool {
    [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code)
  }

  private func cancelUploadSession(_ url: URL) async {
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = "DELETE"
    let session = session
    let cleanup = Task.detached {
      _ = try? await session.authorized(request)
    }
    await cleanup.value
  }

  private func resolve(_ path: RemotePath) async throws -> String {
    if let id = ids[path.value] { return id }
    guard let match = try await entries(parent(path)).first(where: { $0.item.path == path }) else {
      throw RemoteError.posix(ENOENT)
    }
    return match.file.id
  }

  private func invalidate(from path: RemotePath) {
    cacheRevision &+= 1
    let prefix = path.value == "/" ? "/" : path.value + "/"
    ids = ids.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    mimeTypes = mimeTypes.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    ids["/"] = "root"
  }

  private func ensureNameMissing(_ path: RemotePath, name: String? = nil) async throws {
    // 先看 Finder 里的名字有没有被占（同名文件编号后的名字也算）
    do {
      _ = try await resolve(path)
      throw RemoteError.posix(EEXIST)
    } catch RemoteError.posix(ENOENT) {}
    let parentID = try await resolve(parent(path))
    let query = [
      URLQueryItem(
        name: "q",
        value:
          "'\(escaped(parentID))' in parents and name = '\(escaped(name ?? basename(path)))' and trashed = false"
      ),
      URLQueryItem(name: "fields", value: "files(id)"),
      URLQueryItem(name: "pageSize", value: "2"),
    ]
    let response = try await session.authorized(
      URLRequest(url: try url("/files", query: query)))
    try check(response)
    let page = try JSONDecoder().decode(GoogleIDPage.self, from: response.body)
    if !page.files.isEmpty { throw RemoteError.posix(EEXIST) }
  }

  private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.googleapis.com"
    components.path = "/drive/v3" + path
    components.queryItems = query.isEmpty ? nil : query
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { throw RemoteError.invalidPath }
    return url
  }

  private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
  }

  private func ensureDownloadable(path: RemotePath, id: String) async throws {
    let mimeType: String
    if let cached = mimeTypes[path.value] {
      mimeType = cached
    } else {
      let query = [URLQueryItem(name: "fields", value: "mimeType")]
      let response = try await session.authorized(
        URLRequest(url: try url("/files/\(id)", query: query)))
      try check(response)
      mimeType = try JSONDecoder().decode(GoogleMimeType.self, from: response.body).mimeType
      mimeTypes[path.value] = mimeType
    }
    guard
      mimeType != "application/vnd.google-apps.folder",
      !mimeType.hasPrefix("application/vnd.google-apps.")
    else {
      throw RemoteError.unsupported
    }
  }

  private func parent(_ path: RemotePath) -> RemotePath {
    path.parent
  }

  private func basename(_ path: RemotePath) -> String {
    path.basename
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func check(_ response: HTTPResponse, allowing: Set<Int> = [200]) throws {
    if allowing.contains(response.status) { return }
    if response.status == 401 { throw OAuthDriveError.loginRequired }
    throw CloudDriveSupport.mapHTTP(response) ?? OAuthDriveError.invalidResponse
  }
}

private struct GoogleAbout: Decodable {
  struct Quota: Decodable {
    let limit: Int64?
    let usage: Int64?
    enum CodingKeys: String, CodingKey { case limit, usage }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      func bytes(_ key: CodingKeys) throws -> Int64? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = Int64(text), value >= 0 else {
          throw DecodingError.dataCorruptedError(
            forKey: key, in: container, debugDescription: "容量必须是非负的 64 位整数字符串")
        }
        return value
      }
      limit = try bytes(.limit)
      usage = try bytes(.usage)
    }
  }
  let storageQuota: Quota
}

private struct GoogleProfileEnvelope: Decodable {
  struct User: Decodable {
    let permissionId: String?
    let displayName: String?
    let emailAddress: String?
    let photoLink: String?
  }
  let user: User
}

private struct GooglePage: Decodable {
  let files: [GoogleFile]
  let nextPageToken: String?
  enum CodingKeys: String, CodingKey {
    case files
    case nextPageToken
  }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    files = try container.decodeIfPresent([GoogleFile].self, forKey: .files) ?? []
    nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
  }
}

private struct GoogleIDPage: Decodable {
  struct File: Decodable {
    let id: String
  }
  let files: [File]
}

private struct GoogleMimeType: Decodable {
  let mimeType: String
}

private struct GoogleFile: Decodable {
  let id: String
  let name: String
  let mimeType: String
  let size: String?
  let modifiedTime: String?
  var isDirectory: Bool { mimeType == "application/vnd.google-apps.folder" }
  func item(at path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: path.basename, isDirectory: isDirectory,
      size: Int64(size ?? "0") ?? 0,
      modified: RemoteTimestamp.parse(modifiedTime)
        ?? Date(timeIntervalSince1970: 0))
  }
}
