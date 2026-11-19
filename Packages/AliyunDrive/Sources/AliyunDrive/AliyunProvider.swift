import Core
import Foundation

public actor AliyunProvider: RemoteFileProvider {
  // 重名文件分到的编号在本次连接里保持不变
  private let duplicateNames = DuplicateNameMemory()
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: AliyunSession
  private let taskTimeout: Duration
  private let taskDeadline: HTTPProgressDeadline?
  private var driveID: String?
  private var rootID = "root"
  // 路径用 Finder 里显示的名字（同名文件编了号）
  private var paths: [String: AliyunFile] = [:]
  private var cacheGeneration: UInt64 = 0
  private var listings: [String: UUID] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }
  private var links: [String: AliyunDownloadLink] = [:]
  public init(session: AliyunSession) {
    self.init(session: session, taskTimeout: .seconds(RemoteTimeout.cloudRequest))
  }
  init(session: AliyunSession, taskTimeout: Duration, taskDeadline: HTTPProgressDeadline? = nil) {
    self.session = session
    self.taskTimeout = taskTimeout
    self.taskDeadline = taskDeadline
  }
  public func connect() async throws {
    cacheGeneration &+= 1
    let generation = cacheGeneration
    driveID = nil
    paths.removeAll()
    links.removeAll()
    let account = try await session.account()
    guard generation == cacheGeneration else { throw RemoteError.posix(EAGAIN) }
    driveID = account.driveID
    rootID = account.rootFolderID
  }
  public func disconnect() async {
    cacheGeneration &+= 1
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
      try $0.file.item(at: path.appending($0.name))
    }
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    if path.value == "/" {
      _ = try connectedDrive()
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let cached = try await resolve(path)
    let generation = cacheGeneration
    let file: AliyunFile = try await rpc("get", ["file_id": cached.fileID])
    guard generation == cacheGeneration else { throw RemoteError.posix(EAGAIN) }
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
    let file = try await resolve(path)
    let item = try file.item(at: path)
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
    for attempt in 0..<2 {
      let link = try await downloadLink(fileID: file.fileID)
      guard link.method.uppercased() == "GET", link.url.scheme == "https" else {
        throw RemoteError.protocolError
      }
      var request = URLRequest(url: link.url, timeoutInterval: RemoteTimeout.transferIdle)
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
    let progress = self.progress
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let name = basename(path)
    let parentFile = try await resolve(destination)
    guard parentFile.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let entries = try await children(destination, fileID: parentFile.fileID)
    let matches = entries.filter { $0.name == name }.map(\.file)
    // 覆盖同名文件里的某一份后，新文件 ID 变了，编号可能和另一份对调，所以不覆盖
    if let match = matches.first,
      match.name != name || entries.filter({ $0.file.name == match.name }).count > 1
    {
      throw AliyunFileError.duplicateNames
    }
    guard matches.first?.isDirectory != true else { throw RemoteError.posix(EISDIR) }
    let size = try localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size >= 0 else {
      throw RemoteError.failed(EIO, L("读不到要上传的本地文件大小"))
    }
    let parts = try AliyunMultipart.parts(size: Int64(size))
    defer { invalidate(destination) }
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
          else {
            throw RemoteError.failed(
              EIO,
              LF(
                "读取本地文件不完整：从第 %lld 字节起应读 %lld 字节，只读到 %lld 字节（文件可能在上传时被改动）",
                part.offset, part.length, Int64(data.count)))
          }
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
          var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
          request.httpMethod = "PUT"
          request.httpBody = data
          let response = try await session.authorized(request, upload: true)
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
    if let previous = matches.first {
      do {
        let result: AliyunMutation = try await rpc("recyclebin/trash", ["file_id": previous.fileID])
        try await waitForTask(result.asyncTaskID)
      } catch { throw AliyunFileError.replacementCleanupFailed(error) }
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
    guard matches.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer { invalidate(destination) }
    let _: AliyunCreatedFile = try await rpc(
      "create",
      [
        "parent_file_id": parentFile.fileID, "name": basename(path), "type": "folder",
        "check_name_mode": "refuse",
      ])
  }
  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if file.isDirectory, !recursive, !(try await children(path, fileID: file.fileID)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    defer { invalidate(parent(of: path)) }
    let result: AliyunMutation = try await rpc("recyclebin/trash", ["file_id": file.fileID])
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
      $0.name == basename(to) && $0.file.fileID != file.fileID
    }
    guard collisions.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer {
      invalidate(source)
      invalidate(destination)
    }
    // 同名文件在 Finder 里显示的是编号后的名字，这里都按网盘上的真实名字比
    let renameDuringMove =
      source != destination
      && destinationFiles.contains {
        $0.file.name == file.name && $0.file.fileID != file.fileID
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
    if file.name != basename(to), !renameDuringMove {
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
      guard let matched = try await children(current, fileID: file.fileID).first(where: {
        $0.name == name
      }) else { throw RemoteError.posix(ENOENT) }
      file = matched.file
      current = next
    }
    return file
  }
  // 返回每个子项和它在 Finder 里显示的名字
  private func children(
    _ path: RemotePath, fileID: String
  ) async throws -> [(name: String, file: AliyunFile)] {
    let generation = cacheGeneration
    let requestID = UUID()
    listings[path.value] = requestID
    defer {
      if listings[path.value] == requestID { listings.removeValue(forKey: path.value) }
    }
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
    guard generation == cacheGeneration, listings[path.value] == requestID else {
      throw RemoteError.posix(EAGAIN)
    }
    clearCachedPaths(path)
    let names = duplicateNames.assign(
      files.map { DuplicateNames.Entry(id: $0.fileID, name: $0.name, isDirectory: $0.isDirectory) }, in: path.value)
    var result: [(name: String, file: AliyunFile)] = []
    for file in files {
      guard let name = names[file.fileID] else { throw RemoteError.protocolError }
      let child = try path.appending(name)
      _ = try file.item(at: child)
      paths[child.value] = file
      result.append((name, file))
    }
    return result
  }
  private func invalidate(_ directory: RemotePath) {
    cacheGeneration &+= 1
    clearCachedPaths(directory)
  }
  private func clearCachedPaths(_ directory: RemotePath) {
    let prefix = directory.value == "/" ? "/" : directory.value + "/"
    let removed = paths.filter { $0.key.hasPrefix(prefix) }
    for (path, file) in removed {
      paths.removeValue(forKey: path)
      links.removeValue(forKey: file.fileID)
    }
  }
  private func parent(of path: RemotePath) -> RemotePath {
    path.parent
  }
  private func basename(_ path: RemotePath) -> String {
    path.basename
  }
  private func downloadLink(fileID: String) async throws -> AliyunDownloadLink {
    if let link = links[fileID], let expiration = link.expiresAt, expiration > Date() {
      return link
    }
    let generation = cacheGeneration
    let link: AliyunDownloadLink = try await rpc(
      "getDownloadUrl", ["file_id": fileID, "expire_sec": 900])
    guard generation == cacheGeneration else { throw RemoteError.posix(EAGAIN) }
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
    do {
      try await (taskDeadline ?? HTTPProgressDeadline(interval: taskTimeout)).run {
        while true {
          let result: AliyunTaskState = try await self.rpc("async_task/get", ["async_task_id": id])
          switch result.state {
          case "Succeed": return
          case "Failed":
            let detail = [result.code, result.message].compactMap { $0 }.filter { !$0.isEmpty }
            throw RemoteError.failed(
              EIO,
              detail.isEmpty
                ? LF("阿里云盘后台任务 %@ 执行失败，服务器没有说明原因", id)
                : LF("阿里云盘后台任务 %@ 执行失败：%@", id, detail.joined(separator: ": ")))
          case "Running": try await Task.sleep(for: .seconds(1))
          default:
            throw RemoteError.failed(
              EIO, LF("阿里云盘后台任务 %@ 返回了未知状态“%@”", id, result.state))
          }
        }
      }
    } catch let error as URLError where error.code == .timedOut {
      throw RemoteError.posix(ETIMEDOUT)
    }
  }
  private func rpc<T: Decodable>(_ endpoint: String, _ fields: [String: Any]) async throws -> T {
    var body = fields
    body["drive_id"] = try connectedDrive()
    var request = URLRequest(
      url: URL(string: "https://openapi.alipan.com/adrive/v1.0/openFile/" + endpoint)!,
      timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response = try await session.authorized(request)
    try check(response)
    do { return try JSONDecoder().decode(T.self, from: response.body) } catch {
      PackageDiagnostics.failure(error, category: .aliyunDrive, operation: .request)
      throw RemoteError.malformed(
        LF("阿里云盘接口 %@ 返回的数据无法解析：%@", endpoint, Self.decodingDetail(error)))
    }
  }
  private func check(_ response: HTTPResponse) throws {
    guard !(200..<300).contains(response.status) else { return }
    switch response.status {
    case 404: throw RemoteError.posix(ENOENT)
    case 409: throw RemoteError.posix(EEXIST)
    case 429: throw RemoteError.posix(EAGAIN)
    case 507: throw RemoteError.posix(ENOSPC)
    default: break
    }
    // 其余状态码含义笼统：errno 照旧，提示里带上服务器原话和状态码
    let code: Int32 =
      switch response.status {
      case 400: EINVAL
      case 401, 403: EACCES
      default: EIO
      }
    let status = Int64(response.status)
    if let detail = Self.serverDetail(response.body) {
      throw RemoteError.failed(code, LF("阿里云盘返回错误：%@（HTTP %@）", detail, String(status)))
    }
    guard code == EIO else { throw RemoteError.posix(code) }
    throw RemoteError.failed(EIO, LF("阿里云盘请求失败（HTTP %@），服务器没有说明原因", String(status)))
  }
  // 取出错误响应里服务器的原话：开放接口回 JSON（code、message），分片上传的 OSS 回 XML（Code、Message）
  static func serverDetail(_ body: Data) -> String? {
    var parts: [String] = []
    if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
      parts = ["code", "message"].compactMap { object[$0] as? String }
    } else {
      let text = String(decoding: body, as: UTF8.self)
      parts = ["Code", "Message"].compactMap { tag in
        guard let start = text.range(of: "<\(tag)>"),
          let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
      }
      // 不是 XML 的短文本也原样带上，HTML 错误页太长没法看就不放
      let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if parts.isEmpty, !plain.isEmpty, !plain.hasPrefix("<"), plain.count <= 300 {
        parts = [plain]
      }
    }
    parts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: ": ")
  }
  // 说清 JSON 里哪个字段不对，方便发现接口改版
  static func decodingDetail(_ error: Error) -> String {
    guard let error = error as? DecodingError else { return error.localizedDescription }
    func path(_ keys: [CodingKey]) -> String {
      keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
    switch error {
    case .keyNotFound(let key, let context):
      return LF("缺少字段 %@", path(context.codingPath + [key]))
    case .typeMismatch(_, let context): return LF("字段 %@ 的类型不对", path(context.codingPath))
    case .valueNotFound(_, let context): return LF("字段 %@ 为空", path(context.codingPath))
    case .dataCorrupted(let context): return context.debugDescription
    @unknown default: return error.localizedDescription
    }
  }
  static func validContentRange(_ header: String?, requested: Range<Int64>, size: Int64) -> Bool {
    HTTPContentRange.matches(header, requested: requested, size: size)
  }
}
