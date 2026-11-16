import Core
import Foundation

public actor OneDriveProvider: RemoteFileProvider, OAuthProfileProviding {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private let uploadSessionThreshold: Int64
  private let recoverySleep: @Sendable (Duration) async throws -> Void
  private let chunkSize: Int64
  private var connected = false
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: OAuthSession, transport: any HTTPTransport = URLSessionHTTPTransport(),
    uploadSessionThreshold: Int64 = 250 * 1024 * 1024,
    chunkSize: Int64 = 10 * 1024 * 1024
  ) {
    self.init(session: session, transport: transport, uploadSessionThreshold: uploadSessionThreshold,
      chunkSize: chunkSize, recoverySleep: { try await Task.sleep(for: $0) })
  }

  init(session: OAuthSession, transport: any HTTPTransport, uploadSessionThreshold: Int64,
    chunkSize: Int64, recoverySleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.recoverySleep = recoverySleep
    self.session = session
    self.transport = session.limited(transport)
    self.uploadSessionThreshold = uploadSessionThreshold
    self.chunkSize = chunkSize
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    let response = try await session.authorized(
      URLRequest(url: try endpoint("/me/drive/root")))
    try check(response)
    connected = true
  }

  public func disconnect() async { connected = false }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let response = try await session.authorized(
      URLRequest(url: try endpoint("/me/drive?$select=quota")))
    try check(response)
    let root = try JSONDecoder().decode(OneDriveDrive.self, from: response.body)
    return SpaceInfo(total: root.quota.total, used: root.quota.used)
  }

  public func profile() async throws -> OAuthProfile {
    let response = try await session.authorized(
      URLRequest(
        url: try endpoint("/me?$select=id,displayName,userPrincipalName")))
    try check(response)
    let value = try JSONDecoder().decode(OneDriveProfile.self, from: response.body)
    return OAuthProfile(
      userID: value.id,
      nickname: value.displayName ?? value.userPrincipalName ?? "OneDrive")
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    var url = try endpoint(
      path.value == "/"
        ? "/me/drive/root/children" : "/me/drive/root:\(encodedPath(path)):/children")
    var items: [OneDriveItem] = []
    repeat {
      let response = try await session.authorized(URLRequest(url: url))
      try check(response)
      let page = try JSONDecoder().decode(OneDrivePage.self, from: response.body)
      items.append(contentsOf: page.value)
      if let next = page.nextLink {
        guard let parsed = URL(string: next), parsed.scheme == "https",
          parsed.host == "graph.microsoft.com"
        else { throw RemoteError.protocolError }
        url = parsed
      } else {
        break
      }
    } while true
    return try items.map { try $0.item(parent: path) }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let response = try await session.authorized(
      URLRequest(url: try itemURL(path)))
    try check(response)
    return try JSONDecoder().decode(OneDriveItem.self, from: response.body)
      .item(parent: parent(path))
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    var request = URLRequest(url: try itemURL(path, suffix: "/content"))
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= range.upperBound else {
        throw RemoteError.posix(EINVAL)
      }
      if range.isEmpty { return CloudDriveSupport.emptyStream() }
      request.setValue(
        "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
        forHTTPHeaderField: "Range")
    }
    let response = try await session.authorizedStream(request)
    if range != nil {
      guard response.response.status == 206 else {
        if (200..<300).contains(response.response.status) {
          throw RemoteError.protocolError
        }
        try check(response.response)
        throw RemoteError.protocolError
      }
    } else {
      try check(response.response, allowing: [200])
    }
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
    if size <= min(uploadSessionThreshold, 8 * 1024 * 1024) {
      try await directWrite(
        path: path, data: Data(contentsOf: localFile, options: .mappedIfSafe), progress: progress)
      return
    }
    try await sessionWrite(path: path, localFile: localFile, size: size, progress: progress)
  }

  private func directWrite(
    path: RemotePath, data: Data, progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    var request = URLRequest(url: try itemURL(path, suffix: "/content"))
    request.httpMethod = "PUT"
    request.httpBody = data
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("*", forHTTPHeaderField: "If-None-Match")
    try check(try await session.authorized(request, upload: true), allowing: [200, 201])
    progress?(Int64(data.count), Int64(data.count))
  }

  private func sessionWrite(
    path: RemotePath, localFile: URL, size: Int64, progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    guard chunkSize > 0 else { throw RemoteError.posix(EINVAL) }
    var uploadURL = try await startUploadSession(path)
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    do {
      var offset: Int64 = 0
      var restarts = 0
      var recoveries = 0
      var reported: Int64 = 0
      while offset < size {
        try Task.checkCancellation()
        let length = min(chunkSize, size - offset)
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
          throw RemoteError.posix(EIO)
        }
        let end = offset + length
        var request = URLRequest(url: uploadURL, timeoutInterval: RemoteTimeout.transferIdle)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(offset)-\(end - 1)/\(size)", forHTTPHeaderField: "Content-Range")
        var response: HTTPResponse
        var queryStatus = false
        do {
          response = try await CloudDriveSupport.sendWithRetry(
            transport, request, upload: true, retrySafe: false)
          queryStatus = response.status == 416 || (500...599).contains(response.status)
          if (500...599).contains(response.status) {
            guard recoveries < 3 else { try check(response); throw RemoteError.protocolError }
            try await recoverySleep(.seconds(1 << recoveries))
          }
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code) {
          response = HTTPResponse(status: 0)
          queryStatus = true
        }
        if queryStatus {
          guard recoveries < 3 else { throw RemoteError.posix(EIO) }
          recoveries += 1
          // 不猜测上次 PUT 是否生效，先取得服务端缺失范围。
          response = try await transport.send(URLRequest(url: uploadURL,
            timeoutInterval: RemoteTimeout.cloudRequest))
        }
        if response.status == 404 {
          guard restarts < 2 else { try check(response); throw RemoteError.protocolError }
          restarts += 1
          try await ensureMissing(path)
          uploadURL = try await startUploadSession(path)
          offset = 0
          continue
        }
        if !queryStatus, response.status == 200 || response.status == 201 {
          guard end == size else { throw RemoteError.protocolError }
          progress?(size, size)
          return
        }
        try check(response, allowing: queryStatus ? [200] : [202])
        let next = try nextUploadOffset(response, size: size)
        guard next <= end else { throw RemoteError.protocolError }
        if next <= offset {
          guard recoveries < 3 else { throw RemoteError.posix(EIO) }
          recoveries += 1
        }
        offset = next
        reported = max(reported, offset)
        progress?(reported, size)
      }
      throw RemoteError.protocolError
    } catch {
      await cancelUploadSession(uploadURL)
      throw error
    }
  }

  private func startUploadSession(_ path: RemotePath) async throws -> URL {
    var start = URLRequest(
      url: try endpoint("/me/drive/root:\(encodedPath(path)):/createUploadSession"))
    start.httpMethod = "POST"
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.httpBody = try JSONSerialization.data(withJSONObject: [
      "item": ["@microsoft.graph.conflictBehavior": "fail", "name": basename(path)]
    ])
    let response = try await session.authorized(start)
    try check(response, allowing: [200, 201])
    guard let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let rawURL = value["uploadUrl"] as? String,
      let url = URL(string: rawURL), url.scheme == "https", url.host != nil
    else { throw RemoteError.protocolError }
    return url
  }

  private func nextUploadOffset(_ response: HTTPResponse, size: Int64) throws -> Int64 {
    guard let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let ranges = value["nextExpectedRanges"] as? [String], !ranges.isEmpty
    else { throw RemoteError.protocolError }
    return try ranges.map { range in
      let parts = range.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2, let start = Int64(parts[0]), start >= 0, start < size else {
        throw RemoteError.protocolError
      }
      if !parts[1].isEmpty {
        guard let end = Int64(parts[1]), end >= start, end < size else {
          throw RemoteError.protocolError
        }
      }
      return start
    }.min()!
  }

  private func cancelUploadSession(_ url: URL) async {
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = "DELETE"
    let transport = transport
    let cleanup = Task.detached {
      _ = try? await transport.send(request)
    }
    await cleanup.value
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
    let parentURL =
      path.value.split(separator: "/").dropLast().isEmpty
      ? try endpoint("/me/drive/root/children")
      : try endpoint("/me/drive/root:\(encodedPath(parent(path))):/children")
    var request = URLRequest(url: parentURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": basename(path), "folder": [:], "@microsoft.graph.conflictBehavior": "fail",
    ])
    try check(try await session.authorized(request), allowing: [200, 201])
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    if !recursive {
      let item = try await stat(path)
      if item.isDirectory {
        let children = try await list(path)
        if !children.isEmpty { throw RemoteError.posix(ENOTEMPTY) }
      }
    }
    var request = URLRequest(url: try itemURL(path))
    request.httpMethod = "DELETE"
    try check(try await session.authorized(request), allowing: [202, 204])
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    // 网盘不分大小写，只改大小写时查到的「目标」就是源文件自己，不算重名
    if from.value.caseInsensitiveCompare(to.value) != .orderedSame {
      try await ensureMissing(to)
    }
    var body: [String: Any] = ["name": basename(to)]
    if parent(from) != parent(to) {
      let destination = parent(to)
      let url =
        destination.value == "/"
        ? try endpoint("/me/drive/root") : try itemURL(destination)
      let response = try await session.authorized(URLRequest(url: url))
      try check(response)
      let targetParent = try JSONDecoder().decode(OneDriveItem.self, from: response.body)
      guard targetParent.folder != nil else { throw RemoteError.posix(ENOTDIR) }
      body["parentReference"] = ["id": targetParent.id]
    }
    var request = URLRequest(url: try itemURL(from))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    try check(try await session.authorized(request), allowing: [200])
  }

  private func itemURL(_ path: RemotePath, suffix: String = "") throws -> URL {
    try endpoint("/me/drive/root:\(encodedPath(path))" + (suffix.isEmpty ? "" : ":" + suffix))
  }

  private func endpoint(_ value: String) throws -> URL {
    let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var components = URLComponents()
    components.scheme = "https"
    components.host = "graph.microsoft.com"
    components.percentEncodedPath = "/v1.0" + String(parts[0])
    if parts.count == 2 {
      components.percentEncodedQuery = String(parts[1])
    }
    guard let url = components.url else { throw RemoteError.invalidPath }
    return url
  }

  private func encodedPath(_ path: RemotePath) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return "/"
      + path.value.split(separator: "/").map {
        String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      }.joined(separator: "/")
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

  private func check(_ response: HTTPResponse, allowing statuses: Set<Int> = [200]) throws {
    if statuses.contains(response.status) { return }
    if response.status == 401 { throw OAuthDriveError.loginRequired }
    if response.status == 412 { throw RemoteError.posix(EEXIST) }
    throw CloudDriveSupport.mapHTTP(response) ?? OAuthDriveError.invalidResponse
  }
}

private struct OneDriveDrive: Decodable {
  struct Quota: Decodable {
    let total: Int64?
    let used: Int64?
  }
  let quota: Quota
}

private struct OneDriveProfile: Decodable {
  let id: String
  let displayName: String?
  let userPrincipalName: String?
}

private struct OneDrivePage: Decodable {
  let value: [OneDriveItem]
  let nextLink: String?
  enum CodingKeys: String, CodingKey {
    case value
    case nextLink = "@odata.nextLink"
  }
}

private struct OneDriveItem: Decodable {
  struct Folder: Decodable {}
  let id: String
  let name: String
  let size: Int64?
  let lastModifiedDateTime: String?
  let folder: Folder?
  func item(parent: RemotePath) throws -> RemoteItem {
    let date =
      RemoteTimestamp.parse(lastModifiedDateTime)
      ?? Date(timeIntervalSince1970: 0)
    return RemoteItem(
      path: try parent.appending(name), name: name, isDirectory: folder != nil,
      size: folder == nil ? size ?? 0 : 0, modified: date)
  }
}
