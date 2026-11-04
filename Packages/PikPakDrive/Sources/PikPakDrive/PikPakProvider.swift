import Core
import Foundation

public actor PikPakProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: PikPakSession
  private let rootFolderID: String
  private let partSize: Int64
  private var connected = false
  private var paths: [String: PikPakFile] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: PikPakSession, rootFolderID: String = "root", partSize: Int64 = 5 * 1024 * 1024
  ) {
    self.session = session
    self.rootFolderID = rootFolderID
    self.partSize = partSize
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    _ = try await session.account()
    connected = true
    paths.removeAll()
  }

  public func disconnect() async {
    connected = false
    paths.removeAll()
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
    let detailed: PikPakFile = try await rpc(
      method: "GET", path: "/drive/v1/files/" + detailedID(file.id))
    guard let linked = detailed.links?.original?.url, linked.scheme == "https" else {
      throw PikPakError.invalidResponse
    }
    var request = URLRequest(url: linked, timeoutInterval: 60)
    request.httpMethod = "GET"
    if let requested {
      request.setValue(
        "bytes=\(requested.lowerBound)-\(requested.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    let stream = try await session.streamSigned(request)
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

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = basename(path)
    let existing = try await children(destination, folderID: folder.id).filter { $0.name == name }
    guard existing.isEmpty else { throw RemoteError.posix(EEXIST) }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize >= 0 else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    let hash = try PikPakDigest.gcid(localFile, size: size)
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
      try? await discard(newFile.id)
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
      try? await discard(newFile.id)
      if let task = created.task { try? await deleteTask(task.id) }
      throw error
    }
    invalidate(destination)
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
    if let existing = matches.first {
      guard existing.isDirectory else { throw RemoteError.posix(EEXIST) }
      return
    }
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
    invalidate(destination)
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, folderID: file.id)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    struct BatchRequest: Encodable {
      let ids: [String]
    }
    let mutation: PikPakMutation = try await rpc(
      method: "POST", path: "/drive/v1/files:batchTrash",
      body: try PikPakJSON.encode(BatchRequest(ids: [file.id])))
    invalidate(parent(of: path))
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
      if folderID != rootFolderID, folderID != "root" {
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
    invalidate(path)
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(300))
    while ContinuousClock.now < deadline {
      let task: PikPakTask = try await rpc(
        method: "GET", path: "/drive/v1/tasks/" + detailedID(id))
      switch task.phase {
      case "PHASE_TYPE_COMPLETE": return
      case "PHASE_TYPE_ERROR": throw PikPakError.taskFailed
      case "PHASE_TYPE_RUNNING", "PHASE_TYPE_PENDING": try await Task.sleep(for: .milliseconds(500))
      default: throw PikPakError.invalidResponse
      }
    }
    throw RemoteError.posix(ETIMEDOUT)
  }

  private func discard(_ id: String) async throws {
    struct BatchRequest: Encodable { let ids: [String] }
    let _: PikPakMutation = try await rpc(
      method: "POST", path: "/drive/v1/files:batchDelete",
      body: try PikPakJSON.encode(BatchRequest(ids: [id])))
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
    id == rootFolderID || id == "root" ? "" : id
  }

  private func invalidate(_ directory: RemotePath) {
    let prefix = directory.value == "/" ? "/" : directory.value + "/"
    for key in Array(paths.keys) where key.hasPrefix(prefix) { paths.removeValue(forKey: key) }
  }

  private func parent(of path: RemotePath) -> RemotePath {
    try! RemotePath("/" + path.value.split(separator: "/").dropLast().joined(separator: "/"))
  }

  private func basename(_ path: RemotePath) -> String {
    path.value.split(separator: "/").last.map(String.init) ?? ""
  }

  private func detailedID(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  static func validContentRange(
    _ header: String?, requested: Range<Int64>, size: Int64
  ) -> Bool {
    guard let header, header.hasPrefix("bytes ") else { return false }
    let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard fields.count == 2, Int64(fields[1]) == size else { return false }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }
}
