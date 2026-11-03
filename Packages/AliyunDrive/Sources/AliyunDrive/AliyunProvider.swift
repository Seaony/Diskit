import Core
import Foundation

public actor AliyunProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: AliyunSession
  private var driveID: String?
  private var rootID = "root"
  private var paths: [String: AliyunFile] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }
  private var links: [String: AliyunDownloadLink] = [:]
  public init(session: AliyunSession) { self.session = session }
  public func connect() async throws {
    let account = try await session.account()
    driveID = account.driveID
    rootID = account.rootFolderID
    paths.removeAll()
    links.removeAll()
  }
  public func disconnect() async {
    driveID = nil
    paths.removeAll()
    links.removeAll()
  }
  public func spaceInfo() async throws -> SpaceInfo {
    _ = try connectedDrive()
    let account = try await session.account()
    return SpaceInfo(total: account.total, used: account.used)
  }
  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let parent = try await resolve(path)
    guard parent.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, fileID: parent.fileID).map {
      try $0.item(at: path.appending($0.name))
    }
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    if path.value == "/" {
      _ = try connectedDrive()
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let cached = try await resolve(path)
    let file: AliyunFile = try await rpc("get", ["file_id": cached.fileID])
    guard file.name == cached.name else {
      invalidate(parent(of: path))
      throw RemoteError.posix(ENOENT)
    }
    paths[path.value] = file
    return try file.item(at: path)
  }
  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    let item = try await stat(path)
    guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
    let file = try await resolve(path)
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
    for attempt in 0..<2 {
      let link = try await downloadLink(fileID: file.fileID)
      guard link.method.uppercased() == "GET", link.url.scheme == "https" else {
        throw RemoteError.protocolError
      }
      var request = URLRequest(url: link.url, timeoutInterval: 60)
      if let requested {
        request.setValue(
          "bytes=\(requested.lowerBound)-\(requested.upperBound - 1)", forHTTPHeaderField: "Range")
      }
      let stream = try await session.authorizedStream(request)
      if [401, 403].contains(stream.response.status), attempt == 0 {
        links.removeValue(forKey: file.fileID)
        continue
      }
      try check(stream.response)
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
  public func write(_ path: RemotePath, from localFile: URL) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let name = basename(path)
    let parentFile = try await resolve(destination)
    guard parentFile.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let matches = try await children(destination, fileID: parentFile.fileID).filter {
      $0.name == name
    }
    guard matches.count <= 1 else { throw AliyunFileError.duplicateNames }
    guard matches.first?.isDirectory != true else { throw RemoteError.posix(EISDIR) }
    let size = try localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size >= 0 else { throw RemoteError.posix(EIO) }
    let parts = try AliyunMultipart.parts(size: Int64(size))
    let created: AliyunCreatedFile = try await rpc(
      "create",
      [
        "parent_file_id": parentFile.fileID, "name": name, "type": "file",
        "check_name_mode": matches.isEmpty ? "refuse" : "ignore", "size": size,
        "part_info_list": parts.map { ["part_number": $0.number] },
      ])
    guard !created.fileID.isEmpty, created.fileID != matches.first?.fileID else {
      throw RemoteError.protocolError
    }
    let uploaded: AliyunFile
    if created.rapidUpload != true {
      guard let uploadID = created.uploadID, !uploadID.isEmpty else {
        throw RemoteError.protocolError
      }
      let handle = try FileHandle(forReadingFrom: localFile)
      defer { try? handle.close() }
      var urls: [Int: URL] = [:]
      for part in created.partInfoList ?? [] {
        guard part.partNumber > 0, urls[part.partNumber] == nil else {
          throw RemoteError.protocolError
        }
        urls[part.partNumber] = part.uploadURL
      }
      for part in parts {
        try Task.checkCancellation()
        try handle.seek(toOffset: UInt64(part.offset))
        var data = Data()
        while data.count < part.length {
          guard let chunk = try handle.read(upToCount: Int(part.length) - data.count),
            !chunk.isEmpty
          else { throw RemoteError.posix(EIO) }
          data.append(chunk)
        }
        if urls[part.number] == nil {
          urls[part.number] = try await uploadURL(
            fileID: created.fileID, uploadID: uploadID, part: part.number)
        }
        for attempt in 0..<2 {
          guard let url = urls[part.number], url.scheme == "https" else {
            throw RemoteError.protocolError
          }
          var request = URLRequest(url: url, timeoutInterval: 60)
          request.httpMethod = "PUT"
          request.httpBody = data
          let response = try await session.authorized(request)
          if [401, 403].contains(response.status), attempt == 0 {
            urls[part.number] = try await uploadURL(
              fileID: created.fileID, uploadID: uploadID, part: part.number)
            continue
          }
          try check(response)
          progress?(part.offset + part.length, Int64(size))
          break
        }
      }
      uploaded = try await rpc("complete", ["file_id": created.fileID, "upload_id": uploadID])
    } else {
      uploaded = try await rpc("get", ["file_id": created.fileID])
    }
    guard uploaded.fileID == created.fileID, uploaded.type == "file", uploaded.size == Int64(size)
    else { throw RemoteError.protocolError }
    invalidate(destination)
    if let previous = matches.first {
      do {
        let result: AliyunMutation = try await rpc("recyclebin/trash", ["file_id": previous.fileID])
        try await waitForTask(result.asyncTaskID)
      } catch { throw AliyunFileError.replacementCleanupFailed }
    }
  }
  public func makeDirectory(_ path: RemotePath) async throws {
    guard path.value != "/" else {
      _ = try connectedDrive()
      return
    }
    let destination = parent(of: path)
    let parentFile = try await resolve(destination)
    guard parentFile.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let matches = try await children(destination, fileID: parentFile.fileID).filter {
      $0.name == basename(path)
    }
    guard matches.count <= 1 else { throw AliyunFileError.duplicateNames }
    if let existing = matches.first {
      guard existing.isDirectory else { throw RemoteError.posix(EEXIST) }
      return
    }
    let _: AliyunCreatedFile = try await rpc(
      "create",
      [
        "parent_file_id": parentFile.fileID, "name": basename(path), "type": "folder",
        "check_name_mode": "refuse",
      ])
    invalidate(destination)
  }
  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, fileID: file.fileID)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    let result: AliyunMutation = try await rpc("recyclebin/trash", ["file_id": file.fileID])
    invalidate(parent(of: path))
    try await waitForTask(result.asyncTaskID)
  }
  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else { throw RemoteError.posix(EACCES) }
    if from == to { return }
    let file = try await resolve(from)
    let source = parent(of: from)
    let destination = parent(of: to)
    let target = try await resolve(destination)
    guard target.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let destinationFiles = try await children(destination, fileID: target.fileID)
    let collisions = destinationFiles.filter {
      $0.name == basename(to) && $0.fileID != file.fileID
    }
    guard collisions.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer {
      invalidate(source)
      invalidate(destination)
    }
    let renameDuringMove =
      source != destination
      && destinationFiles.contains {
        $0.name == basename(from) && $0.fileID != file.fileID
      }
    if source != destination {
      var parameters: [String: Any] = [
        "file_id": file.fileID, "to_parent_file_id": target.fileID, "check_name_mode": "refuse",
      ]
      if renameDuringMove { parameters["new_name"] = basename(to) }
      let result: AliyunMutation = try await rpc(
        "move", parameters)
      try await waitForTask(result.asyncTaskID)
    }
    if basename(from) != basename(to), !renameDuringMove {
      let _: AliyunFile = try await rpc(
        "update", ["file_id": file.fileID, "name": basename(to), "check_name_mode": "refuse"])
    }
  }
  private func connectedDrive() throws -> String {
    guard let driveID else { throw RemoteError.notConnected }
    return driveID
  }
  private func rootFile() -> AliyunFile {
    AliyunFile(
      fileID: rootID, name: "/", type: "folder", size: 0, updatedAt: "1970-01-01T00:00:00Z")
  }
  private func resolve(_ path: RemotePath) async throws -> AliyunFile {
    _ = try connectedDrive()
    if path.value == "/" { return rootFile() }
    if let file = paths[path.value] { return file }
    var current = try RemotePath("/")
    var file = rootFile()
    for name in path.value.split(separator: "/").map(String.init) {
      guard file.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      let next = try current.appending(name)
      if let cached = paths[next.value] {
        file = cached
        current = next
        continue
      }
      let matches = try await children(current, fileID: file.fileID).filter { $0.name == name }
      guard matches.count <= 1 else { throw AliyunFileError.duplicateNames }
      guard let matched = matches.first else { throw RemoteError.posix(ENOENT) }
      file = matched
      current = next
    }
    return file
  }
  private func children(_ path: RemotePath, fileID: String) async throws -> [AliyunFile] {
    var files: [AliyunFile] = []
    var marker = ""
    var visited: Set<String> = []
    repeat {
      let page: AliyunFileList = try await rpc(
        "list", ["parent_file_id": fileID, "limit": 100, "marker": marker, "fields": "*"])
      files += page.items
      marker = page.nextMarker ?? ""
      if !marker.isEmpty, !visited.insert(marker).inserted { throw RemoteError.protocolError }
    } while !marker.isEmpty
    invalidate(path)
    let counts = Dictionary(grouping: files, by: \.name)
    for file in files {
      let child = try path.appending(file.name)
      _ = try file.item(at: child)
      if counts[file.name]?.count == 1 { paths[child.value] = file }
    }
    return files
  }
  private func invalidate(_ directory: RemotePath) {
    let prefix = directory.value == "/" ? "/" : directory.value + "/"
    let removed = paths.filter { $0.key.hasPrefix(prefix) }
    for (path, file) in removed {
      paths.removeValue(forKey: path)
      links.removeValue(forKey: file.fileID)
    }
  }
  private func parent(of path: RemotePath) -> RemotePath {
    try! RemotePath("/" + path.value.split(separator: "/").dropLast().joined(separator: "/"))
  }
  private func basename(_ path: RemotePath) -> String {
    path.value.split(separator: "/").last.map(String.init) ?? ""
  }
  private func downloadLink(fileID: String) async throws -> AliyunDownloadLink {
    if let link = links[fileID], let expiration = link.expiresAt, expiration > Date() {
      return link
    }
    let link: AliyunDownloadLink = try await rpc(
      "getDownloadUrl", ["file_id": fileID, "expire_sec": 900])
    guard link.expiresAt != nil else { throw RemoteError.protocolError }
    links[fileID] = link
    return link
  }
  private func uploadURL(fileID: String, uploadID: String, part: Int) async throws -> URL {
    let response: AliyunUploadURLs = try await rpc(
      "getUploadUrl",
      ["file_id": fileID, "upload_id": uploadID, "part_info_list": [["part_number": part]]])
    guard let url = response.partInfoList.first(where: { $0.partNumber == part })?.uploadURL else {
      throw RemoteError.protocolError
    }
    return url
  }
  private func waitForTask(_ id: String?) async throws {
    guard let id, !id.isEmpty else { return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
      let result: AliyunTaskState = try await rpc("async_task/get", ["async_task_id": id])
      switch result.state {
      case "Succeed": return
      case "Failed": throw RemoteError.posix(EIO)
      case "Running": try await Task.sleep(for: .seconds(1))
      default: throw RemoteError.protocolError
      }
    }
    throw RemoteError.posix(ETIMEDOUT)
  }
  private func rpc<T: Decodable>(_ endpoint: String, _ fields: [String: Any]) async throws -> T {
    var body = fields
    body["drive_id"] = try connectedDrive()
    var request = URLRequest(
      url: URL(string: "https://openapi.alipan.com/adrive/v1.0/openFile/" + endpoint)!,
      timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response = try await session.authorized(request)
    try check(response)
    do { return try JSONDecoder().decode(T.self, from: response.body) } catch {
      throw RemoteError.protocolError
    }
  }
  private func check(_ response: HTTPResponse) throws {
    guard (200..<300).contains(response.status) else {
      switch response.status {
      case 400: throw RemoteError.posix(EINVAL)
      case 401, 403: throw RemoteError.posix(EACCES)
      case 404: throw RemoteError.posix(ENOENT)
      case 409: throw RemoteError.posix(EEXIST)
      case 429: throw RemoteError.posix(EAGAIN)
      case 507: throw RemoteError.posix(ENOSPC)
      default: throw RemoteError.posix(EIO)
      }
    }
  }
  static func validContentRange(_ header: String?, requested: Range<Int64>, size: Int64) -> Bool {
    guard let header, header.hasPrefix("bytes ") else { return false }
    let pieces = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, Int64(pieces[1]) == size else { return false }
    let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }
}
