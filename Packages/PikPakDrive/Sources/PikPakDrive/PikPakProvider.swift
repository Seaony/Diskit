import Core
import Foundation

public actor PikPakProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: PikPakSession
  private let rootFolderID: String
  private let partSize: Int64
  private let now: @Sendable () -> Date
  private var connected = false
  private var paths: [String: PikPakFile] = [:]
  private var cacheGeneration: UInt64 = 0
  private var listings: [String: UUID] = [:]
  private var downloadLinks: [String: PikPakFile.Link] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: PikPakSession, rootFolderID: String = "root", partSize: Int64 = 5 * 1024 * 1024
  ) {
    self.session = session
    self.rootFolderID = rootFolderID
    self.partSize = partSize
    now = { Date() }
  }

  init(
    session: PikPakSession, rootFolderID: String = "root", partSize: Int64 = 5 * 1024 * 1024,
    now: @escaping @Sendable () -> Date
  ) {
    self.session = session
    self.rootFolderID = rootFolderID
    self.partSize = partSize
    self.now = now
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    connected = false
    cacheGeneration &+= 1
    let generation = cacheGeneration
    paths.removeAll()
    downloadLinks.removeAll()
    _ = try await session.account()
    guard cacheGeneration == generation else { throw CancellationError() }
    connected = true
  }

  public func disconnect() async {
    connected = false
    cacheGeneration &+= 1
    paths.removeAll()
    downloadLinks.removeAll()
    listings.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let account = try await session.account()
    return SpaceInfo(total: account.total, used: account.used)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, folderID: folder.id).map {
      try $0.item(at: path.appending($0.name))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if path.value == "/" { return rootItem(path) }
    return try await resolve(path).item(at: path)
  }

  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    let item = try await stat(path)
    guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
    if item.size == 0 {
      guard range == nil || range?.isEmpty == true else { throw RemoteError.posix(EINVAL) }
      return AsyncThrowingStream { $0.finish() }
    }
    let requested: Range<Int64>?
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= item.size else {
        throw RemoteError.posix(EINVAL)
      }
      requested = range.lowerBound..<min(range.upperBound, item.size)
      if requested?.isEmpty == true { return AsyncThrowingStream { $0.finish() } }
    } else {
      requested = nil
    }
    let file = try await resolve(path)
    for attempt in 0..<2 {
      let link = try await downloadLink(file.id)
      var request = URLRequest(url: link.url, timeoutInterval: RemoteTimeout.transferIdle)
      request.httpMethod = "GET"
      if let requested {
        request.setValue(
          "bytes=\(requested.lowerBound)-\(requested.upperBound - 1)", forHTTPHeaderField: "Range")
      }
      let stream = try await session.streamSigned(request)
      if [401, 403].contains(stream.response.status), attempt == 0 {
        downloadLinks.removeValue(forKey: file.id)
        continue
      }
      try PikPakHTTP.check(stream.response)
      if let requested {
        guard stream.response.status == 206,
          Self.validContentRange(
            stream.response.header("Content-Range"), requested: requested, size: item.size)
        else { throw RemoteError.protocolError }
      } else {
        guard stream.response.status == 200 else { throw RemoteError.protocolError }
      }
      return stream.body
    }
    throw RemoteError.posix(EACCES)
  }

  private func downloadLink(_ id: String) async throws -> PikPakFile.Link {
    if let cached = downloadLinks[id], let expires = cached.expiresAt,
      expires > now().addingTimeInterval(10)
    {
      return cached
    }
    let generation = cacheGeneration
    let detailed: PikPakFile = try await rpc(
      method: "GET", path: "/drive/v1/files/" + detailedID(id))
    try requireConnection()
    guard generation == cacheGeneration else { throw RemoteError.posix(EAGAIN) }
    guard detailed.id == id, let link = detailed.links?.original,
      link.url.scheme == "https", link.url.host != nil
    else { throw PikPakError.invalidResponse }
    if let expires = link.expiresAt, expires > now().addingTimeInterval(10) {
      downloadLinks[id] = link
    }
    return link
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = basename(path)
    let existing = try await children(destination, folderID: folder.id).filter { $0.name == name }
    guard existing.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer { invalidate(destination) }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize >= 0 else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    let generation = cacheGeneration
    let hashing = Task.detached(priority: .utility) { try PikPakDigest.gcid(localFile, size: size) }
    let hash = try await withTaskCancellationHandler {
      try await hashing.value
    } onCancel: {
      hashing.cancel()
    }
    try Task.checkCancellation()
    try requireConnection()
    guard cacheGeneration == generation else { throw RemoteError.posix(EAGAIN) }
    struct CreateRequest: Encodable {
      let kind = "drive#file"
      let name: String
      let parentID: String
      let folderType = "NORMAL"
      let size: Int64
      let hash: String
      let uploadType = "UPLOAD_TYPE_RESUMABLE"
      let resumable = ["provider": "PROVIDER_ALIYUN"]
      enum CodingKeys: String, CodingKey {
        case kind, name, size, hash, resumable
        case parentID = "parent_id"
        case folderType = "folder_type"
        case uploadType = "upload_type"
      }
    }
    let created: PikPakNewFile = try await rpc(
      method: "POST", path: "/drive/v1/files",
      body: try PikPakJSON.encode(
        CreateRequest(
          name: name, parentID: requestParent(folder.id), size: size, hash: hash)))
    guard let newFile = created.file, !newFile.id.isEmpty else {
      throw PikPakError.invalidResponse
    }
    guard newFile.name == name else {
      await cleanupUpload(newFile, taskID: created.task?.id)
      throw RemoteError.posix(EEXIST)
    }
    do {
      if newFile.phase != "PHASE_TYPE_COMPLETE" {
        guard let parameters = created.resumable?.parameters else {
          throw PikPakError.invalidResponse
        }
        try await PikPakS3Uploader(session: session, partSize: partSize).upload(
          from: localFile, size: size, parameters: parameters, progress: progress)
        if let task = created.task { try await waitTask(task.id) }
      } else {
        progress?(size, size)
      }
      guard newFile.size == nil || newFile.size == size else {
        throw PikPakError.invalidResponse
      }
    } catch {
      await cleanupUpload(newFile, taskID: created.task?.id)
      throw error
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    guard path.value != "/" else {
      try requireConnection()
      return
    }
    let destination = parent(of: path)
    let parentFile = try await resolve(destination)
    guard parentFile.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let matches = try await children(destination, folderID: parentFile.id).filter {
      $0.name == basename(path)
    }
    guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
    guard matches.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer { invalidate(destination) }
    struct CreateFolder: Encodable {
      let kind = "drive#folder"
      let name: String
      let parentID: String
      enum CodingKeys: String, CodingKey {
        case kind, name
        case parentID = "parent_id"
      }
    }
    let _: PikPakNewFile = try await rpc(
      method: "POST", path: "/drive/v1/files",
      body: try PikPakJSON.encode(
        CreateFolder(name: basename(path), parentID: requestParent(parentFile.id))))
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, folderID: file.id)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    defer { invalidate(parent(of: path)) }
    struct BatchRequest: Encodable {
      let ids: [String]
    }
    let mutation: PikPakMutation = try await rpc(
      method: "POST", path: "/drive/v1/files:batchTrash",
      body: try PikPakJSON.encode(BatchRequest(ids: [file.id])))
    try await waitTask(mutation.taskID)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else { throw RemoteError.posix(EACCES) }
    if from == to { return }
    let file = try await resolve(from)
    let sourceParent = parent(of: from)
    let destinationParent = parent(of: to)
    let destination = try await resolve(destinationParent)
    guard destination.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let destinationChildren = try await children(destinationParent, folderID: destination.id)
    guard
      !destinationChildren.contains(where: {
        $0.name == basename(to) && $0.id != file.id
      })
    else { throw RemoteError.posix(EEXIST) }

    do {
      if sourceParent != destinationParent {
        struct BatchMove: Encodable {
          struct Target: Encodable {
            let parentID: String
            enum CodingKeys: String, CodingKey { case parentID = "parent_id" }
          }
          let ids: [String]
          let to: Target
        }
        let mutation: PikPakMutation = try await rpc(
          method: "POST", path: "/drive/v1/files:batchMove",
          body: try PikPakJSON.encode(
            BatchMove(ids: [file.id], to: .init(parentID: requestParent(destination.id)))))
        try await waitTask(mutation.taskID)
      }
      if basename(from) != basename(to) {
        struct RenameRequest: Encodable { let name: String }
        let _: PikPakFile = try await rpc(
          method: "PATCH", path: "/drive/v1/files/" + detailedID(file.id),
          body: try PikPakJSON.encode(RenameRequest(name: basename(to))))
      }
    } catch {
      invalidate(sourceParent)
      invalidate(destinationParent)
      throw error
    }
    invalidate(sourceParent)
    invalidate(destinationParent)
  }

  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func rootItem(_ path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: "/", isDirectory: true, size: 0,
      modified: Date(timeIntervalSince1970: 0))
  }

  private func rootFile() -> PikPakFile {
    PikPakFile(
      id: rootFolderID, name: "/", kind: "drive#folder", size: 0,
      modifiedTime: "1970-01-01T00:00:00Z", createdTime: nil, parentID: nil, phase: nil,
      links: nil)
  }

  private func resolve(_ path: RemotePath) async throws -> PikPakFile {
    try requireConnection()
    if path.value == "/" { return rootFile() }
    if let cached = paths[path.value] { return cached }
    var current = try RemotePath("/")
    var folder = rootFile()
    for name in path.value.split(separator: "/").map(String.init) {
      guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      let next = try current.appending(name)
      if let cached = paths[next.value] {
        folder = cached
        current = next
        continue
      }
      let matches = try await children(current, folderID: folder.id).filter { $0.name == name }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let match = matches.first else { throw RemoteError.posix(ENOENT) }
      folder = match
      current = next
    }
    return folder
  }

  private func children(_ path: RemotePath, folderID: String) async throws -> [PikPakFile] {
    let generation = cacheGeneration
    let listing = UUID()
    listings[path.value] = listing
    defer { if listings[path.value] == listing { listings.removeValue(forKey: path.value) } }
    var pageToken = ""
    var visited: Set<String> = []
    var files: [PikPakFile] = []
    repeat {
      var components = URLComponents(
        string: PikPakSession.driveRoot + "/drive/v1/files")!
      var query = [
        URLQueryItem(name: "thumbnail_size", value: "SIZE_MEDIUM"),
        URLQueryItem(name: "limit", value: "500"),
        URLQueryItem(name: "with_audit", value: "true"),
        URLQueryItem(name: "page_token", value: pageToken),
        URLQueryItem(
          name: "filters",
          value:
            #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#),
      ]
      if folderID != "root", !folderID.isEmpty {
        query.append(URLQueryItem(name: "parent_id", value: folderID))
      }
      components.queryItems = query
      guard let url = components.url else { throw PikPakError.invalidResponse }
      let page: PikPakFileList = try await rpc(method: "GET", url: url)
      files.append(contentsOf: page.files)
      pageToken = page.nextPageToken ?? ""
      if !pageToken.isEmpty, !visited.insert(pageToken).inserted {
        throw RemoteError.protocolError
      }
    } while !pageToken.isEmpty
    try requireConnection()
    guard cacheGeneration == generation, listings[path.value] == listing else {
      throw RemoteError.posix(EAGAIN)
    }
    clearCachedChildren(path)
    let grouped = Dictionary(grouping: files, by: \.name)
    for file in files {
      let child = try path.appending(file.name)
      _ = try file.item(at: child)
      if grouped[file.name]?.count == 1 { paths[child.value] = file }
    }
    return files
  }

  private func rpc<T: Decodable>(
    method: String, path: String, body: Data? = nil
  ) async throws -> T {
    let url = URL(string: PikPakSession.driveRoot + path)!
    return try await rpc(method: method, url: url, body: body)
  }

  private func rpc<T: Decodable>(method: String, url: URL, body: Data? = nil) async throws -> T {
    try requireConnection()
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let response = try await session.authorized(request)
    try PikPakHTTP.check(response)
    do { return try JSONDecoder().decode(T.self, from: response.body) } catch {
      throw PikPakError.invalidResponse
    }
  }

  private func waitTask(_ id: String?) async throws {
    guard let id, !id.isEmpty else { return }
    try await waitTask(
      id, deadline: HTTPProgressDeadline(interval: .seconds(RemoteTimeout.transferIdle)),
      pollInterval: .milliseconds(500))
  }

  func waitTask(_ id: String, deadline: HTTPProgressDeadline, pollInterval: Duration) async throws {
    do {
      try await deadline.run {
        try await self.pollTask(id, deadline: deadline, pollInterval: pollInterval)
      }
    } catch {
      throw PikPakHTTP.transportError(error)
    }
  }

  private func pollTask(_ id: String, deadline: HTTPProgressDeadline, pollInterval: Duration)
    async throws
  {
    var progress: Int64 = 0
    while true {
      try Task.checkCancellation()
      let task: PikPakTask = try await rpc(
        method: "GET", path: "/drive/v1/tasks/" + detailedID(id))
      switch task.phase {
      case "PHASE_TYPE_COMPLETE": return
      case "PHASE_TYPE_ERROR": throw PikPakError.taskFailed
      case "PHASE_TYPE_RUNNING", "PHASE_TYPE_PENDING":
        if let current = task.progress, current > progress {
          progress = current
          deadline.recordProgress()
        }
        try await Task.sleep(for: pollInterval)
      default: throw PikPakError.invalidResponse
      }
    }
  }

  func cleanupUpload(_ file: PikPakFile, taskID: String?) async {
    // 上传已取消时也尝试回收，清理错误不能覆盖原始失败。
    let cleanup = Task.detached { [self] in
      let deadline = HTTPProgressDeadline(interval: .seconds(RemoteTimeout.transferIdle))
      do {
        try await deadline.run { await self.performUploadCleanup(file, taskID: taskID) }
      } catch {
        PackageDiagnostics.failure(error, category: .pikPakDrive, operation: .remove)
      }
    }
    await cleanup.value
  }

  private func performUploadCleanup(_ file: PikPakFile, taskID: String?) async {
    do { try await discard(file.id) }
    catch { PackageDiagnostics.failure(error, category: .pikPakDrive, operation: .remove) }
    if let taskID {
      do { try await deleteTask(taskID) }
      catch { PackageDiagnostics.failure(error, category: .pikPakDrive, operation: .remove) }
    }
  }

  private func discard(_ id: String) async throws {
    struct BatchRequest: Encodable { let ids: [String] }
    let mutation: PikPakMutation = try await rpc(
      method: "POST", path: "/drive/v1/files:batchDelete",
      body: try PikPakJSON.encode(BatchRequest(ids: [id])))
    try await waitTask(mutation.taskID)
  }

  private func deleteTask(_ id: String) async throws {
    var components = URLComponents(
      string: PikPakSession.driveRoot + "/drive/v1/tasks")!
    components.queryItems = [
      URLQueryItem(name: "delete_files", value: "false"),
      URLQueryItem(name: "task_ids", value: id),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "DELETE"
    let response = try await session.authorized(request)
    try PikPakHTTP.check(response)
  }

  private func requestParent(_ id: String) -> String {
    id == "root" ? "" : id
  }

  private func invalidate(_ directory: RemotePath) {
    cacheGeneration &+= 1
    clearCachedChildren(directory)
  }

  private func clearCachedChildren(_ directory: RemotePath) {
    let prefix = directory.value == "/" ? "/" : directory.value + "/"
    for key in Array(paths.keys) where key.hasPrefix(prefix) {
      if let file = paths.removeValue(forKey: key) { downloadLinks.removeValue(forKey: file.id) }
    }
  }

  private func parent(of path: RemotePath) -> RemotePath {
    path.parent
  }

  private func basename(_ path: RemotePath) -> String {
    path.basename
  }

  private func detailedID(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  static func validContentRange(
    _ header: String?, requested: Range<Int64>, size: Int64
  ) -> Bool {
    HTTPContentRange.matches(header, requested: requested, size: size)
  }
}
