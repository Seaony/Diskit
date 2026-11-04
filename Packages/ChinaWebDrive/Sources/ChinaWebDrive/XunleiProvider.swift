import Core
import Foundation

private struct XunleiFile: Decodable, Sendable {
  let id: String
  let parentID: String?
  let name: String
  let kind: String
  let phase: String?
  let size: FlexibleInt64?
  let modifiedTime: FlexibleString?
  let webContentLink: URL?
  let medias: [Media]?

  struct Media: Decodable, Sendable {
    let link: Link?
  }
  struct Link: Decodable, Sendable {
    let url: URL?
  }

  enum CodingKeys: String, CodingKey {
    case id, name, kind, phase, size, medias
    case parentID = "parent_id"
    case modifiedTime = "modified_time"
    case webContentLink = "web_content_link"
  }

  var isDirectory: Bool { kind == "drive#folder" }

  func item(at path: RemotePath) throws -> RemoteItem {
    guard ChinaWebSupport.isValidRemoteName(name), !id.isEmpty else {
      throw XunleiError.invalidResponse
    }
    let value = size?.value ?? 0
    guard value >= 0 else { throw XunleiError.invalidResponse }
    return RemoteItem(
      path: path, name: name, isDirectory: isDirectory, size: isDirectory ? 0 : value,
      modified: ChinaWebSupport.parseDate(modifiedTime?.value))
  }
}

private struct XunleiPage: Decodable {
  let files: [XunleiFile]
  let nextPageToken: String?
  enum CodingKeys: String, CodingKey {
    case files
    case nextPageToken = "next_page_token"
  }
}

private struct XunleiAbout: Decodable {
  struct Quota: Decodable {
    let limit: FlexibleInt64?
    let usage: FlexibleInt64?
  }
  let quota: Quota?
}

private struct XunleiFileWrapper: Decodable {
  let file: XunleiFile
}

private struct XunleiResumable: Decodable, Sendable {
  struct Parameters: Decodable, Sendable {
    let endpoint: String
    let region: String?
    let accessKeyID: String
    let accessKeySecret: String
    let bucket: String
    let securityToken: String?
    let key: String
    let partSize: FlexibleInt64?

    enum CodingKeys: String, CodingKey {
      case endpoint, region, bucket, key
      case accessKeyID = "access_key_id"
      case accessKeySecret = "access_key_secret"
      case securityToken = "security_token"
      case partSize = "part_size"
    }
  }

  let provider: String
  let params: Parameters
}

private struct XunleiUploadResponse: Decodable {
  let uploadType: String
  let file: XunleiFile
  let resumable: XunleiResumable?

  enum CodingKeys: String, CodingKey {
    case file, resumable
    case uploadType = "upload_type"
  }
}

public actor XunleiProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: XunleiSession
  private let rootFolderID: String
  private let uploader: any XunleiVendorUploader
  private var connected = false
  private var nodes: [String: XunleiFile] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(session: XunleiSession, rootFolderID: String = "") {
    self.session = session
    self.rootFolderID = rootFolderID
    self.uploader = AliyunOSSXunleiUploader()
  }

  init(
    session: XunleiSession,
    rootFolderID: String = "",
    uploader: any XunleiVendorUploader
  ) {
    self.session = session
    self.rootFolderID = rootFolderID
    self.uploader = uploader
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    try await session.connect()
    connected = true
    nodes.removeAll()
  }

  public func disconnect() async {
    connected = false
    nodes.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let response = try await session.request(method: "GET", path: "about")
    guard let about = try? JSONDecoder().decode(XunleiAbout.self, from: response.body),
      let quota = about.quota, let total = quota.limit?.value, let used = quota.usage?.value,
      total >= 0, used >= 0, used <= total
    else { throw XunleiError.invalidResponse }
    return SpaceInfo(total: total, used: used)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, parentID: folder.id).map {
      try $0.item(at: path.appending($0.name))
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if path.value == "/" { return rootItem(path) }
    return try await resolve(path).item(at: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    let metadata = try await stat(path)
    guard !metadata.isDirectory else { throw RemoteError.posix(EISDIR) }
    guard let node = nodes[path.value] else { throw RemoteError.posix(ENOENT) }
    let requested: Range<Int64>?
    if let range {
      guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
        range.lowerBound <= metadata.size
      else { throw RemoteError.posix(EINVAL) }
      requested = range.lowerBound..<min(range.upperBound, metadata.size)
    } else {
      requested = nil
    }
    if metadata.size == 0 || requested?.isEmpty == true {
      return AsyncThrowingStream { $0.finish() }
    }
    let detailed = try await detail(node.id)
    guard let url = downloadURL(detailed) else { throw XunleiError.invalidResponse }
    for attempt in 0..<2 {
      let stream = try await session.download(url, range: requested)
      if [401, 403].contains(stream.response.status), attempt == 0 {
        let refreshedDetail = try await detail(node.id)
        guard let replacement = downloadURL(refreshedDetail) else {
          throw XunleiError.invalidResponse
        }
        let retried = try await session.download(replacement, range: requested)
        try validate(stream: retried, requested: requested, size: metadata.size)
        return retried.body
      }
      try validate(stream: stream, requested: requested, size: metadata.size)
      return stream.body
    }
    throw RemoteError.posix(EACCES)
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = ChinaWebSupport.parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = ChinaWebSupport.basename(path)
    let existing = try await children(destination, parentID: folder.id)
    guard !existing.contains(where: { $0.name == name }) else {
      throw RemoteError.posix(EEXIST)
    }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize >= 0
    else { throw RemoteError.posix(EIO) }
    let size = Int64(fileSize)
    let response = try await session.request(
      method: "POST",
      path: "files",
      json: [
        "kind": "drive#file",
        "parent_id": requestParent(folder.id),
        "name": name,
        "size": size,
        "space": "",
        "resumable": ["supported_providers": ["PROVIDER_ALIYUN"]],
        "upload_type": "UPLOAD_TYPE_RESUMABLE",
      ])
    let created = try JSONDecoder().decode(XunleiUploadResponse.self, from: response.body)
    guard !created.file.id.isEmpty, created.file.name == name,
      created.file.kind == "drive#file",
      created.file.size == nil || created.file.size?.value == size
    else {
      if !created.file.id.isEmpty { try? await trash(created.file.id) }
      throw RemoteError.posix(EEXIST)
    }
    if created.file.phase == "PHASE_TYPE_COMPLETE" {
      progress?(size, size)
      invalidate(destination)
      return
    }
    if created.file.phase == "PHASE_TYPE_ERROR" {
      try? await trash(created.file.id)
      throw XunleiError.invalidResponse
    }
    guard created.uploadType == "UPLOAD_TYPE_RESUMABLE",
      let resumable = created.resumable,
      resumable.provider == "PROVIDER_ALIYUN"
    else {
      try? await trash(created.file.id)
      throw XunleiError.unsupportedUploadProvider
    }
    let parameters: XunleiUploadParameters
    do {
      parameters = try uploadParameters(resumable.params)
    } catch {
      try? await trash(created.file.id)
      throw error
    }

    do {
      try await uploader.upload(
        from: localFile, size: size, parameters: parameters, progress: progress)
      try await waitForUpload(created.file.id, name: name, size: size)
      progress?(size, size)
      invalidate(destination)
    } catch {
      await discard(created.file.id)
      throw error
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    guard path.value != "/" else {
      try requireConnection()
      return
    }
    let destination = ChinaWebSupport.parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = ChinaWebSupport.basename(path)
    let existing = try await children(destination, parentID: folder.id)
    guard !existing.contains(where: { $0.name == name }) else {
      throw RemoteError.posix(EEXIST)
    }
    let response = try await session.request(
      method: "POST", path: "files",
      json: ["kind": "drive#folder", "parent_id": requestParent(folder.id), "name": name])
    let created = try decodeFile(response.body)
    guard created.name == name else {
      try? await trash(created.id)
      throw RemoteError.posix(EEXIST)
    }
    invalidate(destination)
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, parentID: file.id)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    try await trash(file.id)
    invalidate(ChinaWebSupport.parent(of: path))
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else { throw RemoteError.posix(EACCES) }
    if from == to { return }
    let file = try await resolve(from)
    let source = ChinaWebSupport.parent(of: from)
    let destination = ChinaWebSupport.parent(of: to)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let conflicts = try await children(destination, parentID: folder.id).filter {
      $0.name == ChinaWebSupport.basename(to) && $0.id != file.id
    }
    guard conflicts.isEmpty else { throw RemoteError.posix(EEXIST) }
    let response = try await session.request(
      method: "POST",
      path: "files/\(ChinaWebSupport.encodedPathComponent(file.id))/move",
      json: [
        "to": [
          "parent_id": requestParent(folder.id),
          "name": ChinaWebSupport.basename(to),
        ]
      ])
    let moved = try decodeFile(response.body)
    guard moved.name == ChinaWebSupport.basename(to),
      moved.parentID == nil || moved.parentID == requestParent(folder.id)
    else { throw XunleiError.invalidResponse }
    invalidate(source)
    invalidate(destination)
  }

  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func root() -> XunleiFile {
    XunleiFile(
      id: rootFolderID, parentID: nil, name: "/", kind: "drive#folder", phase: nil, size: nil,
      modifiedTime: nil, webContentLink: nil, medias: nil)
  }

  private func rootItem(_ path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: "/", isDirectory: true, size: 0,
      modified: Date(timeIntervalSince1970: 0))
  }

  private func resolve(_ path: RemotePath) async throws -> XunleiFile {
    try requireConnection()
    if path.value == "/" { return root() }
    if let cached = nodes[path.value] { return cached }
    var currentPath = try RemotePath("/")
    var current = root()
    for component in path.value.split(separator: "/").map(String.init) {
      guard current.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      let nextPath = try currentPath.appending(component)
      if let cached = nodes[nextPath.value] {
        current = cached
        currentPath = nextPath
        continue
      }
      let matches = try await children(currentPath, parentID: current.id).filter {
        $0.name == component
      }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let match = matches.first else { throw RemoteError.posix(ENOENT) }
      current = match
      currentPath = nextPath
    }
    return current
  }

  private func children(_ path: RemotePath, parentID: String) async throws -> [XunleiFile] {
    var pageToken = ""
    var visited = Set<String>()
    var output: [XunleiFile] = []
    repeat {
      try Task.checkCancellation()
      let query = [
        URLQueryItem(name: "parent_id", value: requestParent(parentID)),
        URLQueryItem(name: "page_token", value: pageToken),
        URLQueryItem(name: "limit", value: "100"),
        URLQueryItem(
          name: "filters",
          value: #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#),
      ]
      let response = try await session.request(method: "GET", path: "files", query: query)
      let page = try JSONDecoder().decode(XunleiPage.self, from: response.body)
      output.append(contentsOf: page.files)
      pageToken = page.nextPageToken ?? ""
      if !pageToken.isEmpty, !visited.insert(pageToken).inserted {
        throw XunleiError.invalidResponse
      }
    } while !pageToken.isEmpty
    invalidate(path)
    let grouped = Dictionary(grouping: output, by: \.name)
    for item in output {
      let child = try path.appending(item.name)
      _ = try item.item(at: child)
      if grouped[item.name]?.count == 1 { nodes[child.value] = item }
    }
    return output
  }

  private func detail(_ id: String) async throws -> XunleiFile {
    var components = URLComponents(
      url: XunleiSession.apiBase.appending(
        path: "files/\(ChinaWebSupport.encodedPathComponent(id))"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "usage", value: "DISPLAY")]
    let response = try await session.request(method: "GET", url: components.url!)
    return try JSONDecoder().decode(XunleiFile.self, from: response.body)
  }

  private func decodeFile(_ data: Data) throws -> XunleiFile {
    if let file = try? JSONDecoder().decode(XunleiFile.self, from: data) {
      return file
    }
    if let wrapper = try? JSONDecoder().decode(XunleiFileWrapper.self, from: data) {
      return wrapper.file
    }
    throw XunleiError.invalidResponse
  }

  private func downloadURL(_ file: XunleiFile) -> URL? {
    file.webContentLink ?? file.medias?.lazy.compactMap(\.link?.url).first
  }

  private func uploadParameters(_ parameters: XunleiResumable.Parameters) throws
    -> XunleiUploadParameters
  {
    guard !parameters.accessKeyID.isEmpty, !parameters.accessKeySecret.isEmpty,
      !parameters.bucket.isEmpty, !parameters.key.isEmpty
    else { throw XunleiError.invalidResponse }
    let endpointText =
      parameters.endpoint.contains("://")
      ? parameters.endpoint : "https://" + parameters.endpoint
    guard let endpoint = URL(string: endpointText), endpoint.scheme == "https",
      let host = endpoint.host?.lowercased(),
      host == "aliyuncs.com" || host.hasSuffix(".aliyuncs.com"),
      endpoint.user == nil, endpoint.password == nil,
      endpoint.port == nil || endpoint.port == 443,
      endpoint.path.isEmpty || endpoint.path == "/",
      endpoint.query == nil, endpoint.fragment == nil
    else { throw XunleiError.invalidResponse }
    let requestedPartSize = parameters.partSize?.value ?? 0
    let partSize = requestedPartSize > 0 ? requestedPartSize : 1024 * 1024
    guard partSize >= 100 * 1024, partSize <= 5 * 1024 * 1024 * 1024 else {
      throw XunleiError.invalidResponse
    }
    return XunleiUploadParameters(
      endpoint: endpoint,
      region: parameters.region,
      accessKeyID: parameters.accessKeyID,
      accessKeySecret: parameters.accessKeySecret,
      bucket: parameters.bucket,
      securityToken: parameters.securityToken,
      key: parameters.key,
      partSize: partSize
    )
  }

  private func waitForUpload(_ id: String, name: String, size: Int64) async throws {
    for attempt in 0..<120 {
      let file = try await detail(id)
      guard file.id == id, file.name == name, file.kind == "drive#file" else {
        throw XunleiError.invalidResponse
      }
      if file.phase == "PHASE_TYPE_COMPLETE" {
        guard file.size == nil || file.size?.value == size else {
          throw XunleiError.invalidResponse
        }
        return
      }
      if file.phase == "PHASE_TYPE_ERROR" {
        throw XunleiError.invalidResponse
      }
      if attempt < 119 {
        try await Task.sleep(for: .milliseconds(500))
      }
    }
    throw RemoteError.posix(ETIMEDOUT)
  }

  private func validate(
    stream: HTTPStreamResponse, requested: Range<Int64>?, size: Int64
  ) throws {
    try ChinaWebSupport.checkHTTP(stream.response)
    if let requested {
      guard stream.response.status == 206,
        ChinaWebSupport.validRange(
          stream.response.header("Content-Range"), requested: requested, size: size)
      else { throw RemoteError.protocolError }
    } else {
      guard stream.response.status == 200 else { throw RemoteError.protocolError }
    }
  }

  private func trash(_ id: String) async throws {
    let _ = try await session.request(
      method: "POST", path: "files:batchDelete", json: ["ids": [id], "space": ""])
  }

  private func requestParent(_ id: String) -> String {
    id == rootFolderID ? "" : id
  }

  private func invalidate(_ path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    for key in Array(nodes.keys) where key.hasPrefix(prefix) {
      nodes.removeValue(forKey: key)
    }
  }

  private func discard(_ fileID: String) async {
    let session = session
    let cleanup = Task.detached {
      _ = try? await session.request(
        method: "POST", path: "files:batchDelete", json: ["ids": [fileID]])
    }
    _ = await cleanup.value
  }
}
