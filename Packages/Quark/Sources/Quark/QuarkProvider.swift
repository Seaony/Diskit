import Core
import Foundation
import UniformTypeIdentifiers

public actor QuarkProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: QuarkSession
  private var connected = false
  private var paths: [String: QuarkFile] = [:]
  private var cacheRevision: UInt64 = 0
  private var listings: [String: UUID] = [:]
  private var downloadLinks: [String: (url: URL, size: Int64, updatedAt: Int64)] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  public init(session: QuarkSession) { self.session = session }
  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }
  public func connect() async throws {
    cacheRevision &+= 1
    let revision = cacheRevision
    connected = false
    paths.removeAll()
    downloadLinks.removeAll()
    _ = try await session.account()
    guard revision == cacheRevision else { throw RemoteError.posix(EAGAIN) }
    connected = true
  }
  public func disconnect() async {
    cacheRevision &+= 1
    connected = false
    paths.removeAll()
    downloadLinks.removeAll()
  }
  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let account = try await session.account()
    return SpaceInfo(total: account.total, used: account.used)
  }
  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, fid: folder.fid).map {
      try $0.item(at: path.appending($0.name))
    }
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let parent = parent(of: path)
    let folder = try await resolve(parent)
    guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
    let matches = try await children(parent, fid: folder.fid).filter { $0.name == basename(path) }
    guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
    guard let file = matches.first else { throw RemoteError.posix(ENOENT) }
    return try file.item(at: path)
  }
  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    let metadata = try await stat(path)
    guard !metadata.isDirectory else { throw RemoteError.posix(EISDIR) }
    let file = try await resolve(path)
    let requested: Range<Int64>?
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= metadata.size else {
        throw RemoteError.posix(EINVAL)
      }
      requested = range.lowerBound..<min(range.upperBound, metadata.size)
    } else {
      requested = nil
    }
    if metadata.size == 0 || requested?.isEmpty == true {
      return AsyncThrowingStream { $0.finish() }
    }
    for attempt in 0..<2 {
      let url = try await downloadURL(for: file)
      var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
      if let requested {
        request.setValue(
          "bytes=\(requested.lowerBound)-\(requested.upperBound - 1)", forHTTPHeaderField: "Range")
      }
      let download = try await session.authorizedStream(request)
      if [401, 403].contains(download.response.status), attempt == 0 {
        downloadLinks.removeValue(forKey: file.fid)
        continue
      }
      try checkHTTP(download.response)
      if let requested {
        guard download.response.status == 206,
          Self.validRange(
            download.response.header("Content-Range"), requested: requested, size: metadata.size)
        else { throw RemoteError.protocolError }
      } else {
        guard download.response.status == 200 else { throw RemoteError.protocolError }
      }
      return download.body
    }
    throw RemoteError.posix(EACCES)
  }
  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
    let existing = try await children(destination, fid: folder.fid)
    guard !existing.contains(where: { $0.name == basename(path) }) else {
      throw RemoteError.posix(EEXIST)
    }
    let attributes = try localFile.resourceValues(forKeys: [
      .fileSizeKey, .creationDateKey, .contentModificationDateKey,
    ])
    guard let size = attributes.fileSize, size >= 0 else { throw RemoteError.posix(EIO) }
    let contentType =
      UTType(filenameExtension: (basename(path) as NSString).pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
    let now = Date()
    invalidate(destination)
    defer { invalidate(destination) }
    let pre: QuarkPreUpload = try await rpc(
      "/file/upload/pre",
      body: [
        "ccp_hash_update": true, "dir_name": "", "file_name": basename(path),
        "format_type": contentType,
        "l_created_at": Int64((attributes.creationDate ?? now).timeIntervalSince1970 * 1000),
        "l_updated_at": Int64(
          (attributes.contentModificationDate ?? now).timeIntervalSince1970 * 1000),
        "pdir_fid": folder.fid, "size": size,
      ])
    guard !pre.data.taskID.isEmpty else { throw RemoteError.protocolError }
    let hashTask = Task.detached { try QuarkDigests.file(localFile) }
    let hashes = try await withTaskCancellationHandler {
      try await hashTask.value
    } onCancel: {
      hashTask.cancel()
    }
    try Task.checkCancellation()
    try requireConnection()
    let result: QuarkData<QuarkHashResult> = try await rpc(
      "/file/update/hash",
      body: ["task_id": pre.data.taskID, "md5": hashes.md5, "sha1": hashes.sha1])
    if result.data.finish {
      progress?(Int64(size), Int64(size))
      return
    }
    let parts = try QuarkPart.split(size: Int64(size), partSize: pre.metadata.partSize)
    guard !pre.data.uploadID.isEmpty, !pre.data.authInfo.isEmpty else {
      throw RemoteError.protocolError
    }
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    var etags: [String] = []
    for part in parts {
      try Task.checkCancellation()
      try handle.seek(toOffset: UInt64(part.offset))
      var payload = Data()
      while payload.count < part.length {
        guard let block = try handle.read(upToCount: Int(part.length) - payload.count),
          !block.isEmpty
        else { throw RemoteError.posix(EIO) }
        payload.append(block)
      }
      let date = QuarkOSS.date()
      let headers = ["x-oss-date": date, "x-oss-user-agent": QuarkOSS.client]
      let canonical = QuarkOSS.canonical(
        method: "PUT", contentType: contentType, date: date, headers: headers,
        resource: QuarkOSS.resource(pre.data, part: part.number))
      let authorization = try await authorizeUpload(pre, canonical: canonical)
      var request = URLRequest(
        url: try QuarkOSS.url(pre.data, part: part.number),
        timeoutInterval: RemoteTimeout.transferIdle)
      request.httpMethod = "PUT"
      request.httpBody = payload
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      request.setValue(session.configuration.refererURL, forHTTPHeaderField: "Referer")
      for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
      let uploaded = try await session.authorized(request, upload: true)
      try checkHTTP(uploaded)
      guard let etag = uploaded.header("ETag"), !etag.isEmpty else {
        throw RemoteError.protocolError
      }
      etags.append(etag)
      progress?(part.offset + part.length, Int64(size))
    }
    let body = QuarkOSS.completeBody(etags)
    let md5 = QuarkOSS.contentMD5(body)
    let callback = try QuarkOSS.callback(pre.data.callback)
    let date = QuarkOSS.date()
    let headers = [
      "x-oss-date": date, "x-oss-user-agent": QuarkOSS.client, "x-oss-callback": callback,
    ]
    let canonical = QuarkOSS.canonical(
      method: "POST", contentMD5: md5, contentType: "application/xml", date: date, headers: headers,
      resource: QuarkOSS.resource(pre.data, part: nil))
    let authorization = try await authorizeUpload(pre, canonical: canonical)
    var completion = URLRequest(
      url: try QuarkOSS.url(pre.data, part: nil), timeoutInterval: RemoteTimeout.transferIdle)
    completion.httpMethod = "POST"
    completion.httpBody = body
    completion.setValue(authorization, forHTTPHeaderField: "Authorization")
    completion.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    completion.setValue(md5, forHTTPHeaderField: "Content-MD5")
    completion.setValue(session.configuration.refererURL, forHTTPHeaderField: "Referer")
    for (key, value) in headers { completion.setValue(value, forHTTPHeaderField: key) }
    let committed = try await session.authorized(completion)
    try checkHTTP(committed)
    let _: QuarkStatus = try await rpc(
      "/file/upload/finish", body: ["obj_key": pre.data.objectKey, "task_id": pre.data.taskID])
  }
  public func makeDirectory(_ path: RemotePath) async throws {
    if path.value == "/" {
      try requireConnection()
      return
    }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
    let existing = try await children(destination, fid: folder.fid).filter {
      $0.name == basename(path)
    }
    guard existing.count <= 1 else { throw RemoteError.posix(EEXIST) }
    guard existing.isEmpty else { throw RemoteError.posix(EEXIST) }
    invalidate(destination)
    defer { invalidate(destination) }
    let _: QuarkStatus = try await rpc(
      "/file",
      body: [
        "dir_init_lock": false, "dir_path": "", "file_name": basename(path), "pdir_fid": folder.fid,
      ])
  }
  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let file = try await resolve(path)
    if !file.file, !recursive, !(try await children(path, fid: file.fid)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    invalidate(parent(of: path))
    defer { invalidate(parent(of: path)) }
    let result: QuarkMutation = try await rpc(
      "/file/delete", body: ["action_type": 1, "exclude_fids": [String](), "filelist": [file.fid]])
    try await waitForTask(result.data?.taskID)
  }
  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else { throw RemoteError.posix(EACCES) }
    if from == to { return }
    let source = parent(of: from)
    let destination = parent(of: to)
    let file = try await resolve(from)
    let folder = try await resolve(destination)
    guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
    let destinationFiles = try await children(destination, fid: folder.fid)
    let conflicts = destinationFiles.filter {
      $0.name == basename(to) && $0.fid != file.fid
    }
    guard conflicts.isEmpty else { throw RemoteError.posix(EEXIST) }
    let originalParent = try await resolve(source)
    invalidate(source)
    invalidate(destination)
    defer {
      invalidate(source)
      invalidate(destination)
    }
    if source != destination {
      if basename(from) != basename(to),
        destinationFiles.contains(where: { $0.name == basename(from) && $0.fid != file.fid })
      {
        let temporaryName = ".kayoi-move-" + UUID().uuidString
        try await rename(file.fid, to: temporaryName)
        var moved = false
        do {
          try await moveFile(file.fid, to: folder.fid)
          moved = true
          try await rename(file.fid, to: basename(to))
        } catch {
          let originalError = error
          let restoreParent = moved
          let originalName = basename(from)
          let recovery = Task.detached {
            if restoreParent { try await self.moveFile(file.fid, to: originalParent.fid) }
            try await self.rename(file.fid, to: originalName)
          }
          do { try await recovery.value } catch {
            throw QuarkMoveRecoveryError(
              original: originalError, recovery: error, temporaryName: temporaryName)
          }
          throw originalError
        }
        return
      }
      try await moveFile(file.fid, to: folder.fid)
    }
    if basename(from) != basename(to) {
      try await rename(file.fid, to: basename(to))
    }
  }
  private func rename(_ fid: String, to name: String) async throws {
    let _: QuarkStatus = try await rpc("/file/rename", body: ["fid": fid, "file_name": name])
  }
  private func moveFile(_ fid: String, to parentID: String) async throws {
    let result: QuarkMutation = try await rpc(
      "/file/move",
      body: [
        "action_type": 1, "exclude_fids": [String](), "filelist": [fid],
        "to_pdir_fid": parentID,
      ])
    try await waitForTask(result.data?.taskID)
  }
  private func waitForTask(_ id: String?) async throws {
    guard let id, !id.isEmpty else { return }
    try await HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest)).run {
      var retry = 0
      while true {
        try Task.checkCancellation()
        let result: QuarkData<QuarkTask> = try await self.rpc(
          "/task", method: "GET", query: ["task_id": id, "retry_index": String(retry)])
        switch result.data.status {
        case 2: return
        case 0, 1:
          retry += 1
          try await Task.sleep(for: .milliseconds(500))
        case 3, 4: throw RemoteError.posix(EIO)
        default: throw RemoteError.protocolError
        }
      }
    }
  }
  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }
  private func root() -> QuarkFile {
    QuarkFile(fid: "0", fileName: "/", file: false, size: 0, updatedAt: 0)
  }
  private func resolve(_ path: RemotePath) async throws -> QuarkFile {
    try requireConnection()
    if path.value == "/" { return root() }
    if let file = paths[path.value] { return file }
    var current = try RemotePath("/")
    var folder = root()
    for name in path.value.split(separator: "/").map(String.init) {
      guard !folder.file else { throw RemoteError.posix(ENOTDIR) }
      let next = try current.appending(name)
      if let cached = paths[next.value] {
        folder = cached
        current = next
        continue
      }
      let matches = try await children(current, fid: folder.fid).filter { $0.name == name }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let file = matches.first else { throw RemoteError.posix(ENOENT) }
      folder = file
      current = next
    }
    return folder
  }
  private func children(_ path: RemotePath, fid: String) async throws -> [QuarkFile] {
    let revision = cacheRevision
    let requestID = UUID()
    listings[path.value] = requestID
    defer { if listings[path.value] == requestID { listings.removeValue(forKey: path.value) } }
    var page = 1
    var output: [QuarkFile] = []
    var total = 0
    var restarted = false
    repeat {
      let result: QuarkFileList = try await rpc(
        "/file/sort", method: "GET",
        query: [
          "pdir_fid": fid, "_page": String(page), "_size": "100", "_fetch_total": "1",
          "fetch_all_file": "1", "fetch_risk_file_name": "1",
        ])
      total = result.metadata.total
      guard connected, revision == cacheRevision, listings[path.value] == requestID else {
        throw RemoteError.posix(EAGAIN)
      }
      guard total >= 0 else { throw RemoteError.protocolError }
      if result.data.list.isEmpty, output.count < total {
        guard !restarted else { throw RemoteError.protocolError }
        restarted = true
        page = 1
        output = []
        continue
      }
      output += result.data.list
      page += 1
    } while output.count < total
    let prefix = path.value == "/" ? "/" : path.value + "/"
    let currentIDs = Set(output.map(\.fid))
    for (key, file) in paths where key.hasPrefix(prefix) && !currentIDs.contains(file.fid) {
      downloadLinks.removeValue(forKey: file.fid)
    }
    clearCached(path)
    let grouped = Dictionary(grouping: output, by: \.name)
    for file in output {
      let child = try path.appending(file.name)
      _ = try file.item(at: child)
      if grouped[file.name]?.count == 1 { paths[child.value] = file }
    }
    return output
  }
  private func invalidate(_ path: RemotePath) {
    cacheRevision &+= 1
    downloadLinks.removeAll()
    clearCached(path)
  }
  private func clearCached(_ path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    for key in Array(paths.keys) where key.hasPrefix(prefix) { paths.removeValue(forKey: key) }
  }
  private func parent(of path: RemotePath) -> RemotePath {
    path.parent
  }
  private func basename(_ path: RemotePath) -> String {
    path.basename
  }
  private func downloadURL(for file: QuarkFile) async throws -> URL {
    if let cached = downloadLinks[file.fid], cached.size == file.size,
      cached.updatedAt == file.updatedAt
    {
      return cached.url
    }
    let revision = cacheRevision
    let response: QuarkData<[QuarkDownload]> = try await rpc(
      "/file/download", body: ["fids": [file.fid]])
    guard connected, revision == cacheRevision else { throw RemoteError.posix(EAGAIN) }
    guard let url = response.data.first?.downloadURL, url.scheme == "https",
      let host = url.host?.lowercased(),
      host == session.configuration.cookieDomain
        || host.hasSuffix("." + session.configuration.cookieDomain)
    else { throw RemoteError.protocolError }
    downloadLinks[file.fid] = (url, file.size, file.updatedAt)
    return url
  }
  private func authorizeUpload(_ pre: QuarkPreUpload, canonical: String) async throws -> String {
    let result: QuarkData<QuarkUploadAuthorization> = try await rpc(
      "/file/upload/auth",
      body: ["auth_info": pre.data.authInfo, "auth_meta": canonical, "task_id": pre.data.taskID])
    guard !result.data.authKey.isEmpty else { throw RemoteError.protocolError }
    return result.data.authKey
  }
  private func rpc<T: Decodable>(
    _ path: String, method: String = "POST", query: [String: String] = [:],
    body: [String: Any]? = nil
  ) async throws -> T {
    try requireConnection()
    var components = URLComponents(string: session.configuration.apiBase + path)!
    components.queryItems =
      [
        URLQueryItem(name: "pr", value: session.configuration.clientParameter),
        URLQueryItem(name: "fr", value: "pc"),
      ]
      + query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
    var request = URLRequest(url: components.url!, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let response = try await session.authorized(request)
    try checkHTTP(response)
    do {
      let status = try JSONDecoder().decode(QuarkStatus.self, from: response.body)
      guard status.status < 400, status.code == 0 else { throw RemoteError.posix(EIO) }
      return try JSONDecoder().decode(T.self, from: response.body)
    } catch let error as RemoteError { throw error } catch { throw RemoteError.protocolError }
  }
  private func checkHTTP(_ response: HTTPResponse) throws {
    guard (200..<300).contains(response.status) else {
      switch response.status {
      case 401: throw QuarkError.loginRequired
      default: throw RemoteError.http(response.status)
      }
    }
  }
  static func validRange(_ header: String?, requested: Range<Int64>, size: Int64) -> Bool {
    HTTPContentRange.matches(header, requested: requested, size: size)
  }
}
