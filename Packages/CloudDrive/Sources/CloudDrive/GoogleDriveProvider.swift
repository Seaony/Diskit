import Core
import Foundation

public actor GoogleDriveProvider: RemoteFileProvider, OAuthProfileProviding {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private var ids: [String: String] = ["/": "root"]
  private var mimeTypes: [String: String] = [:]
  private var connected = false
  private let chunkSize = 8 * 1024 * 1024

  public init(session: OAuthSession) { self.session = session }

  public func connect() async throws {
    let response = try await session.authorized(
      URLRequest(url: try url("/about", query: [URLQueryItem(name: "fields", value: "user")])))
    try check(response)
    connected = true
  }

  public func disconnect() async {
    connected = false
    ids = ["/": "root"]
    mimeTypes = [:]
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let response = try await session.authorized(
      URLRequest(
        url: try url("/about", query: [URLQueryItem(name: "fields", value: "storageQuota")])))
    try check(response)
    let value = try JSONDecoder().decode(GoogleAbout.self, from: response.body)
    return SpaceInfo(
      total: Int64(value.storageQuota.limit ?? 0), used: Int64(value.storageQuota.usage ?? 0))
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
    let parentID = try await resolve(path)
    var pageToken: String?
    var items: [GoogleFile] = []
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
      items.append(contentsOf: page.files)
      pageToken = page.nextPageToken
    } while pageToken != nil
    return try items.map {
      let item = try $0.item(parent: path)
      mimeTypes[item.path.value] = $0.mimeType
      return item
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
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
    mimeTypes[path.value] = file.mimeType
    return try file.item(parent: parent(path))
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
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    try await ensureMissing(path)
    let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
    if data.count <= 5 * 1024 * 1024 {
      let metadata = try JSONSerialization.data(withJSONObject: [
        "name": basename(path), "parents": [try await resolve(parent(path))],
      ])
      let boundary = "kayoi-" + UUID().uuidString
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
      try check(try await session.authorized(request), allowing: [200, 201])
    } else {
      try await resumableWrite(path: path, data: data)
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
    let parentID = try await resolve(parent(path))
    var request = URLRequest(url: try url("/files"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": basename(path), "mimeType": "application/vnd.google-apps.folder",
      "parents": [parentID],
    ])
    try check(try await session.authorized(request), allowing: [200, 201])
    ids.removeValue(forKey: parent(path).value)
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
    try await ensureMissing(to)
    let id = try await resolve(from)
    let oldParent = try await resolve(parent(from))
    let newParent = try await resolve(parent(to))
    var components = URLComponents(url: try url("/files/\(id)"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "addParents", value: newParent),
      URLQueryItem(name: "removeParents", value: oldParent),
      URLQueryItem(name: "fields", value: "id,name,parents"),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": basename(to)])
    try check(try await session.authorized(request), allowing: [200])
    invalidate(from: parent(from))
    invalidate(from: parent(to))
  }

  private func resumableWrite(path: RemotePath, data: Data) async throws {
    var start = URLRequest(
      url: URL(
        string:
          "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name")!)
    start.httpMethod = "POST"
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
    start.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
    start.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": basename(path), "parents": [try await resolve(parent(path))],
    ])
    let started = try await session.authorized(start)
    try check(started, allowing: [200])
    guard let location = started.header("Location"), let uploadURL = URL(string: location),
      uploadURL.scheme == "https"
    else { throw RemoteError.protocolError }
    do {
      var offset = 0
      while offset < data.count {
        try Task.checkCancellation()
        let end = min(offset + chunkSize, data.count)
        var chunk = URLRequest(url: uploadURL)
        chunk.httpMethod = "PUT"
        chunk.httpBody = data.subdata(in: offset..<end)
        chunk.setValue(
          "bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
        let response = try await session.authorized(chunk)
        try check(response, allowing: [200, 201, 308])
        offset = end
      }
    } catch {
      await cancelUploadSession(uploadURL)
      throw error
    }
  }

  private func cancelUploadSession(_ url: URL) async {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "DELETE"
    let session = session
    let cleanup = Task.detached {
      _ = try? await session.authorized(request)
    }
    await cleanup.value
  }

  private func resolve(_ path: RemotePath) async throws -> String {
    if let id = ids[path.value] { return id }
    var currentPath = try RemotePath("/")
    var currentID = "root"
    for component in path.value.split(separator: "/") {
      let next = try currentPath.appending(String(component))
      if let cached = ids[next.value] {
        currentPath = next
        currentID = cached
        continue
      }
      let query = [
        URLQueryItem(
          name: "q",
          value:
            "'\(escaped(currentID))' in parents and name = '\(escaped(String(component)))' and trashed = false"
        ),
        URLQueryItem(name: "fields", value: "files(id,name,mimeType)"),
        URLQueryItem(name: "pageSize", value: "2"),
      ]
      let response = try await session.authorized(URLRequest(url: try url("/files", query: query)))
      try check(response)
      let page = try JSONDecoder().decode(GooglePage.self, from: response.body)
      guard !page.files.isEmpty else { throw RemoteError.posix(ENOENT) }
      guard page.files.count == 1 else { throw RemoteError.posix(EEXIST) }
      currentID = page.files[0].id
      ids[next.value] = currentID
      mimeTypes[next.value] = page.files[0].mimeType
      currentPath = next
    }
    return currentID
  }

  private func invalidate(from path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    ids = ids.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    mimeTypes = mimeTypes.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    ids["/"] = "root"
  }

  private func ensureMissing(_ path: RemotePath) async throws {
    let parentID = try await resolve(parent(path))
    let query = [
      URLQueryItem(
        name: "q",
        value:
          "'\(escaped(parentID))' in parents and name = '\(escaped(basename(path)))' and trashed = false"
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
    let parts = path.value.split(separator: "/").dropLast()
    return try! RemotePath(parts.isEmpty ? "/" : "/" + parts.joined(separator: "/"))
  }

  private func basename(_ path: RemotePath) -> String {
    String(path.value.split(separator: "/").last ?? "")
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
  func item(parent: RemotePath) throws -> RemoteItem {
    RemoteItem(
      path: try parent.appending(name), name: name,
      isDirectory: mimeType == "application/vnd.google-apps.folder",
      size: Int64(size ?? "0") ?? 0,
      modified: modifiedTime.flatMap(ISO8601DateFormatter().date)
        ?? Date(timeIntervalSince1970: 0))
  }
}
