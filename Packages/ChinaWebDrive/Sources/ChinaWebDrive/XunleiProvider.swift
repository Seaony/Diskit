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
  // 同目录重名时由列目录分配的「名称 (2)」
  var assignedName: String?

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
  // Finder 里显示的名字
  var displayName: String { assignedName ?? name }

  func item(at path: RemotePath) throws -> RemoteItem {
    guard ChinaWebSupport.isValidRemoteName(name), !id.isEmpty else {
      throw XunleiError.invalidResponse
    }
    let value = size?.value ?? 0
    guard value >= 0 else { throw XunleiError.invalidResponse }
    return RemoteItem(
      path: path, name: displayName, isDirectory: isDirectory, size: isDirectory ? 0 : value,
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
  // 重名文件分到的编号在本次连接里保持不变
  private let duplicateNames = DuplicateNameMemory()
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: XunleiSession
  private let rootFolderID: String
  private let uploader: any XunleiVendorUploader
  private let uploadPollInterval: Duration
  private let uploadIdleTimeout: Duration
  private let makeUploadDeadline: (@Sendable () -> HTTPProgressDeadline)?
  private var connected = false
  private var cacheGeneration: UInt64 = 0
  private var nodes: [String: XunleiFile] = [:]
  // 下载地址按文件 id 缓存，文件大小或修改时间变了就不用
  private var downloadLinks:
    [String: (url: URL, size: Int64?, modified: String?, fetchedAt: Date)] = [:]
  static let downloadLinkTTL: TimeInterval = 5 * 60
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(session: XunleiSession, rootFolderID: String = "") {
    self.session = session
    self.rootFolderID = rootFolderID
    self.uploader = AliyunOSSXunleiUploader()
    uploadPollInterval = .milliseconds(500)
    uploadIdleTimeout = .seconds(RemoteTimeout.transferIdle)
    makeUploadDeadline = nil
  }

  init(
    session: XunleiSession,
    rootFolderID: String = "",
    uploader: any XunleiVendorUploader,
    uploadPollInterval: Duration = .milliseconds(500),
    uploadIdleTimeout: Duration = .seconds(RemoteTimeout.transferIdle),
    makeUploadDeadline: (@Sendable () -> HTTPProgressDeadline)? = nil
  ) {
    self.session = session
    self.rootFolderID = rootFolderID
    self.uploader = uploader
    self.uploadPollInterval = uploadPollInterval
    self.uploadIdleTimeout = uploadIdleTimeout
    self.makeUploadDeadline = makeUploadDeadline
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    connected = false
    cacheGeneration &+= 1
    let generation = cacheGeneration
    nodes.removeAll()
    downloadLinks.removeAll()
    try await session.connect()
    guard cacheGeneration == generation else { throw CancellationError() }
    connected = true
  }

  public func disconnect() async {
    connected = false
    cacheGeneration &+= 1
    nodes.removeAll()
    downloadLinks.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let response = try await session.request(method: "GET", path: "about")
    guard let about = try? JSONDecoder().decode(XunleiAbout.self, from: response.body)
    else { throw XunleiError.invalidResponse }
    let total = about.quota?.limit?.value
    let used = about.quota?.usage?.value
    guard [total, used].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
      throw XunleiError.invalidResponse
    }
    return SpaceInfo(total: total, used: used)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, parentID: folder.id).map {
      try $0.item(at: path.appending($0.displayName))
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
    let node = try await resolve(path)
    let metadata = try node.item(at: path)
    guard !metadata.isDirectory else { throw RemoteError.posix(EISDIR) }
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
    for attempt in 0..<2 {
      let url = try await downloadURL(for: node)
      let stream = try await session.download(url, range: requested)
      if [401, 403].contains(stream.response.status), attempt == 0 {
        downloadLinks.removeValue(forKey: node.id)
        continue
      }
      try validate(stream: stream, requested: requested, size: metadata.size)
      return stream.body
    }
    throw RemoteError.posix(EACCES)
  }

  private func downloadURL(for node: XunleiFile) async throws -> URL {
    let now = Date()
    if let cached = downloadLinks[node.id], cached.size == node.size?.value,
      cached.modified == node.modifiedTime?.value,
      now.timeIntervalSince(cached.fetchedAt) < Self.downloadLinkTTL
    {
      return cached.url
    }
    let generation = cacheGeneration
    guard let url = downloadURL(try await detail(node.id)) else {
      throw XunleiError.invalidResponse
    }
    // 请求期间目录有改动就不缓存，免得记住改动前的地址
    if generation == cacheGeneration {
      downloadLinks = downloadLinks.filter {
        now.timeIntervalSince($0.value.fetchedAt) < Self.downloadLinkTTL
      }
      downloadLinks[node.id] = (url, node.size?.value, node.modifiedTime?.value, now)
    }
    return url
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = ChinaWebSupport.parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = ChinaWebSupport.basename(path)
    let existing = try await children(destination, parentID: folder.id)
    guard !existing.contains(where: { $0.displayName == name }) else {
      throw RemoteError.posix(EEXIST)
    }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize >= 0
    else { throw RemoteError.failed(EIO, LF("要上传的不是普通文件，或读不到它的大小：%@", localFile.path)) }
    let size = Int64(fileSize)
    defer { invalidate(destination) }
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
    } catch {
      await discard(created.file.id)
      throw NetworkFailure.posix(error)
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
    guard !existing.contains(where: { $0.displayName == name }) else {
      throw RemoteError.posix(EEXIST)
    }
    defer { invalidate(destination) }
    let response = try await session.request(
      method: "POST", path: "files",
      json: ["kind": "drive#folder", "parent_id": requestParent(folder.id), "name": name])
    let created = try decodeFile(response.body)
    guard created.name == name else {
      try? await trash(created.id)
      throw RemoteError.posix(EEXIST)
    }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, parentID: file.id)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    defer { invalidate(ChinaWebSupport.parent(of: path)) }
    try await trash(file.id)
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
      $0.displayName == ChinaWebSupport.basename(to) && $0.id != file.id
    }
    guard conflicts.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer {
      invalidate(source)
      invalidate(destination)
    }
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
      guard
        let match = try await children(currentPath, parentID: current.id).first(where: {
          $0.displayName == component
        })
      else { throw RemoteError.posix(ENOENT) }
      current = match
      currentPath = nextPath
    }
    return current
  }

  private func children(_ path: RemotePath, parentID: String) async throws -> [XunleiFile] {
    let generation = cacheGeneration
    var completed = false
    defer {
      if !completed, connected, cacheGeneration == generation { invalidate(path) }
    }
    var pageToken = ""
    var visited = Set<String>()
    var output: [XunleiFile] = []
    var ids = Set<String>()
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
      for file in page.files {
        guard ids.insert(file.id).inserted else { throw XunleiError.invalidResponse }
        output.append(file)
      }
      pageToken = page.nextPageToken ?? ""
      if !pageToken.isEmpty, !visited.insert(pageToken).inserted {
        throw XunleiError.invalidResponse
      }
    } while !pageToken.isEmpty
    let names = duplicateNames.assign(
      output.map { .init(id: $0.id, name: $0.name, isDirectory: $0.isDirectory) }, in: path.value)
    var updated: [String: XunleiFile] = [:]
    for index in output.indices {
      output[index].assignedName = names[output[index].id]
      let child = try path.appending(output[index].displayName)
      _ = try output[index].item(at: child)
      updated[child.value] = output[index]
    }
    if connected, cacheGeneration == generation {
      invalidate(path)
      nodes.merge(updated) { _, new in new }
    }
    completed = true
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
    let deadline = makeUploadDeadline?() ?? HTTPProgressDeadline(interval: uploadIdleTimeout)
    let interval = uploadPollInterval
    try await deadline.run {
      var runningObserved = false
      while true {
        try Task.checkCancellation()
        let file = try await self.detail(id)
        guard file.id == id, file.name == name, file.kind == "drive#file" else {
          throw XunleiError.invalidResponse
        }
        if file.phase == "PHASE_TYPE_COMPLETE" {
          guard file.size == nil || file.size?.value == size else {
            throw XunleiError.invalidResponse
          }
          return
        }
        if file.phase == "PHASE_TYPE_ERROR" { throw XunleiError.invalidResponse }
        if file.phase == "PHASE_TYPE_RUNNING", !runningObserved {
          runningObserved = true
          deadline.recordProgress()
        }
        if interval > .zero { try await Task.sleep(for: interval) }
      }
    }
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
      method: "PATCH", path: "files/\(ChinaWebSupport.encodedPathComponent(id))/trash",
      json: [String: String]())
  }

  private func requestParent(_ id: String) -> String {
    id == rootFolderID ? "" : id
  }

  private func invalidate(_ path: RemotePath) {
    cacheGeneration &+= 1
    let prefix = path.value == "/" ? "/" : path.value + "/"
    for key in Array(nodes.keys) where key.hasPrefix(prefix) {
      nodes.removeValue(forKey: key)
    }
  }

  private func discard(_ fileID: String) async {
    let session = session
    let cleanup = Task.detached {
      _ = try? await session.request(
        method: "PATCH", path: "files/\(ChinaWebSupport.encodedPathComponent(fileID))/trash",
        json: [String: String]())
    }
    _ = await cleanup.value
  }
}
