import Core
import CryptoKit
import Foundation

public struct BaiduDriveConfiguration: Sendable, Equatable {
  public let rootPath: String
  public let appID: String
  public init(rootPath: String, appID: String) {
    self.rootPath = "/" + rootPath.split(separator: "/").joined(separator: "/")
    self.appID = appID
  }
}

public actor BaiduDriveProvider: RemoteFileProvider, OAuthProfileProviding {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let configuration: BaiduDriveConfiguration
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private var connected = false
  private var userID: UInt64 = 0
  private var vipType = 0
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  private let now: @Sendable () -> Date
  // 目录列表短时间内直接拿来回答 stat 和 read，免得 Finder 每读一块都把整个目录列一遍
  private var listings: [String: (entries: [BaiduItem], fetched: Date)] = [:]
  private var listingGeneration: UInt64 = 0
  private var downloadLinks: [UInt64: BaiduDownloadLink] = [:]
  static let listingLifetime: TimeInterval = 30
  // 百度的下载地址 8 小时内有效，留出余量
  static let downloadLinkLifetime: TimeInterval = 4 * 3_600

  public init(
    configuration: BaiduDriveConfiguration, session: OAuthSession,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.init(
      configuration: configuration, session: session, transport: transport, now: { Date() })
  }

  init(
    configuration: BaiduDriveConfiguration, session: OAuthSession, transport: any HTTPTransport,
    now: @escaping @Sendable () -> Date
  ) {
    self.configuration = configuration
    self.session = session
    self.transport = session.limited(transport)
    self.now = now
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    let response = try await request(
      method: "GET", path: "/rest/2.0/xpan/nas",
      query: [URLQueryItem(name: "method", value: "uinfo")])
    let value = try decode(BaiduUser.self, from: response)
    userID = value.uk ?? 0
    vipType = value.vipType ?? 0
    connected = true
  }

  public func disconnect() async {
    connected = false
    invalidateListings()
    downloadLinks.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let response = try await request(method: "GET", path: "/api/quota")
    let value = try decode(BaiduQuota.self, from: response)
    return SpaceInfo(total: value.total, used: value.used)
  }

  public func profile() async throws -> OAuthProfile {
    let response = try await request(
      method: "GET", path: "/rest/2.0/xpan/nas",
      query: [
        URLQueryItem(name: "method", value: "uinfo"),
        URLQueryItem(name: "vip_version", value: "v2"),
      ])
    let value = try decode(BaiduUser.self, from: response)
    return OAuthProfile(
      userID: String(value.uk ?? 0),
      nickname: value.netdisk_name ?? value.baidu_name ?? L("百度网盘"),
      avatarURL: value.avatar_url)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    return try await listEntries(path).map { try $0.item(root: configuration.rootPath) }
  }

  private func listEntries(_ path: RemotePath) async throws -> [BaiduItem] {
    let directory = remotePath(path)
    let generation = listingGeneration
    var start = 0
    var result: [BaiduItem] = []
    while true {
      let response = try await request(
        method: "GET", path: "/rest/2.0/xpan/file",
        query: [
          URLQueryItem(name: "method", value: "list"),
          URLQueryItem(name: "dir", value: directory),
          URLQueryItem(name: "start", value: String(start)),
          URLQueryItem(name: "limit", value: "1000"),
          URLQueryItem(name: "order", value: "name"),
          URLQueryItem(name: "desc", value: "0"),
        ])
      let page = try decode(BaiduListResponse.self, from: response)
      guard page.errno == 0, let entries = page.list ?? page.data?.list else {
        throw RemoteError.protocolError
      }
      for entry in entries {
        _ = try entry.item(root: configuration.rootPath)
        let prefix = directory == "/" ? "/" : directory + "/"
        guard entry.path.hasPrefix(prefix),
          !entry.path.dropFirst(prefix.count).contains("/")
        else { throw RemoteError.protocolError }
      }
      result.append(contentsOf: entries)
      guard entries.count == 1_000 else { break }
      start += entries.count
    }
    // 列表期间有改动就不缓存，免得旧结果盖掉改动
    if generation == listingGeneration {
      let current = now()
      listings = listings.filter { current.timeIntervalSince($0.value.fetched) < Self.listingLifetime }
      listings[path.value] = (result, current)
    }
    return result
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0))
    }
    let item = try await metadata(path)
    return try item.item(root: configuration.rootPath)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    if let range, range.lowerBound < 0 || range.lowerBound > range.upperBound {
      throw RemoteError.posix(EINVAL)
    }
    if range?.isEmpty == true { return CloudDriveSupport.emptyStream() }
    let entry = try await metadata(path)
    guard let id = entry.fs_id else { throw RemoteError.protocolError }
    for attempt in 0..<2 {
      let rawLink = try await downloadLink(entry, id: id)
      let token = try await session.accessToken()
      guard let link = URL(string: rawLink), link.scheme?.lowercased() == "https",
        link.host != nil, link.user == nil, link.password == nil
      else { throw RemoteError.protocolError }
      let url = try CloudDriveSupport.url(
        rawLink, query: [URLQueryItem(name: "access_token", value: token)])
      var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
      request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
      if let range {
        request.setValue(
          "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
          forHTTPHeaderField: "Range")
      }
      let response = try await CloudDriveSupport.streamWithRetry(transport, request)
      // 下载地址过期会返回 403，换一个新地址再试一次
      if response.response.status == 403, attempt == 0 {
        downloadLinks.removeValue(forKey: id)
        continue
      }
      if let error = CloudDriveSupport.mapHTTP(response.response) { throw error }
      if range != nil, response.response.status != 206 { throw RemoteError.protocolError }
      return response.body
    }
    throw RemoteError.posix(EACCES)
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let target = remotePath(path)
    try await ensureMissing(path)
    defer { invalidateListings() }
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw CloudDriveSupport.localFileUnreadable(localFile)
    }
    let size = Int64(fileSize)
    let blockSize: Int64 =
      vipType == 2 ? 32 * 1024 * 1024 : vipType == 1 ? 16 * 1024 * 1024 : 4 * 1024 * 1024
    let blocks = try makeBlocks(file: localFile, size: size, blockSize: blockSize)
    let blockJSON = try jsonString(blocks.md5)
    let precreate = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [URLQueryItem(name: "method", value: "precreate")],
      fields: [
        "path": target, "size": String(size), "isdir": "0", "block_list": blockJSON,
        "autoinit": "1", "rtype": "0",
      ])
    let prepared = try decode(BaiduPrecreate.self, from: precreate)
    if prepared.return_type == 2 {
      progress?(size, size)
      return
    }
    guard let uploadID = prepared.uploadid, !uploadID.isEmpty,
      let parts = prepared.block_list,
      Set(parts).count == parts.count,
      parts.allSatisfy({ blocks.md5.indices.contains($0) })
    else { throw RemoteError.protocolError }
    var confirmedHashes = blocks.md5
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    var uploaded =
      size
      - parts.reduce(Int64(0)) { total, part in
        total + min(blockSize, size - Int64(part) * blockSize)
      }
    for part in parts {
      try Task.checkCancellation()
      let offset = Int64(part) * blockSize
      try handle.seek(toOffset: UInt64(offset))
      let length = min(blockSize, size - offset)
      let data = try handle.read(upToCount: Int(length)) ?? Data()
      guard data.count == Int(length) else {
        throw CloudDriveSupport.localShortRead(
          localFile, offset: offset, expected: length, actual: data.count)
      }
      var form = MultipartFormData()
      form.addFile("file", filename: "part-\(part)", data: data)
      let url = try CloudDriveSupport.url(
        "https://d.pcs.baidu.com/rest/2.0/pcs/superfile2",
        query: [
          URLQueryItem(name: "method", value: "upload"),
          URLQueryItem(name: "access_token", value: try await session.accessToken()),
          URLQueryItem(name: "type", value: "tmpfile"),
          URLQueryItem(name: "path", value: target),
          URLQueryItem(name: "uploadid", value: uploadID),
          URLQueryItem(name: "partseq", value: String(part)),
        ])
      let uploadRequest = CloudDriveSupport.multipartRequest(
        url, form: form, headers: ["User-Agent": "pan.baidu.com"])
      let partResponse = try await upload(uploadRequest)
      let reply = try decode(BaiduUploadPart.self, from: partResponse)
      guard reply.md5.lowercased() == blocks.md5[part] else { throw RemoteError.protocolError }
      confirmedHashes[part] = reply.md5.lowercased()
      uploaded += Int64(data.count)
      progress?(uploaded, size)
    }
    let created = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [URLQueryItem(name: "method", value: "create")],
      fields: [
        "path": target, "size": String(size), "isdir": "0",
        "block_list": try jsonString(confirmedHashes), "uploadid": uploadID, "rtype": "0",
      ])
    let done = try decode(BaiduCreated.self, from: created)
    guard done.errno == 0 else { throw mapBusiness(done.errno) }
    guard done.fs_id != nil else { throw RemoteError.protocolError }
    progress?(size, size)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
    defer { invalidateListings() }
    let response = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [URLQueryItem(name: "method", value: "create")],
      fields: ["path": remotePath(path), "isdir": "1", "rtype": "0"])
    let result = try decode(BaiduCreated.self, from: response)
    guard result.errno == 0 else { throw mapBusiness(result.errno) }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let item = try await stat(path)
    if !recursive, item.isDirectory, try await !list(path).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    let entries = try jsonString([["path": remotePath(path)]])
    defer { invalidateListings() }
    let response = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [
        URLQueryItem(name: "method", value: "filemanager"),
        URLQueryItem(name: "opera", value: "delete"),
      ],
      fields: ["async": "0", "filelist": entries])
    try checkBaidu(response)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    try await ensureMissing(to)
    let targetParent = try await stat(CloudDriveSupport.parent(to))
    guard targetParent.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let entries = try jsonString([
      [
        "path": remotePath(from), "dest": remotePath(CloudDriveSupport.parent(to)),
        "newname": CloudDriveSupport.basename(to),
      ]
    ])
    defer { invalidateListings() }
    let response = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [
        URLQueryItem(name: "method", value: "filemanager"),
        URLQueryItem(name: "opera", value: "move"),
      ],
      fields: ["async": "0", "filelist": entries, "ondup": "fail"])
    try checkBaidu(response)
  }

  private func metadata(_ path: RemotePath) async throws -> BaiduItem {
    let parent = CloudDriveSupport.parent(path)
    let entries: [BaiduItem]
    if let cached = listings[parent.value],
      now().timeIntervalSince(cached.fetched) < Self.listingLifetime
    {
      entries = cached.entries
    } else {
      entries = try await listEntries(parent)
    }
    let matches = entries.filter { $0.path == remotePath(path) }
    guard let match = matches.first else { throw RemoteError.posix(ENOENT) }
    guard matches.count == 1 else { throw RemoteError.posix(EEXIST) }
    return match
  }

  private func downloadLink(_ match: BaiduItem, id: UInt64) async throws -> String {
    let current = now()
    if let cached = downloadLinks[id], cached.size == match.size,
      cached.modified == match.server_mtime,
      current.timeIntervalSince(cached.fetched) < Self.downloadLinkLifetime
    {
      return cached.link
    }
    let response = try await request(
      method: "GET", path: "/rest/2.0/xpan/multimedia",
      query: [
        URLQueryItem(name: "method", value: "filemetas"),
        URLQueryItem(name: "fsids", value: try jsonString([id])),
        URLQueryItem(name: "dlink", value: "1"),
      ])
    let value = try decode(BaiduListResponse.self, from: response)
    let items = value.list ?? value.data?.list ?? []
    guard items.count == 1, let item = items.first,
      item.fs_id == id, item.path == match.path, let link = item.dlink
    else { throw RemoteError.protocolError }
    downloadLinks = downloadLinks.filter {
      current.timeIntervalSince($0.value.fetched) < Self.downloadLinkLifetime
    }
    downloadLinks[id] = BaiduDownloadLink(
      link: link, size: match.size, modified: match.server_mtime, fetched: current)
    return link
  }

  private func invalidateListings() {
    listings.removeAll()
    listingGeneration &+= 1
  }

  private func request(
    method: String, path: String, query: [URLQueryItem] = [], fields: [String: String] = [:]
  ) async throws -> HTTPResponse {
    let url = try CloudDriveSupport.url(
      "https://pan.baidu.com" + path,
      query: query + [URLQueryItem(name: "access_token", value: try await session.accessToken())])
    var request: URLRequest
    if method == "GET" {
      request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
      request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    } else {
      request = CloudDriveSupport.formRequest(
        url, method: method, fields: fields, headers: ["User-Agent": "pan.baidu.com"])
    }
    return try await retryBusinessAuthentication(
      ifNeeded: try await authorized(request), request: request)
  }

  private func authorized(_ request: URLRequest) async throws -> HTTPResponse {
    let first = try await CloudDriveSupport.sendWithRetry(transport, request)
    guard first.status == 401 else { return first }
    _ = try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request))
    let retry = try await replacingAccessToken(in: request)
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry)
    if second.status == 401 {
      throw OAuthDriveError.loginRequired
    }
    return second
  }

  private func upload(_ request: URLRequest) async throws -> HTTPResponse {
    let first = try await CloudDriveSupport.sendWithRetry(transport, request, upload: true)
    guard first.status == 401 || isBusinessUnauthorized(first) else { return first }
    _ = try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request))
    let retry = try await replacingAccessToken(in: request)
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry, upload: true)
    if second.status == 401 || isBusinessUnauthorized(second) {
      throw OAuthDriveError.loginRequired
    }
    return second
  }

  private func retryBusinessAuthentication(
    ifNeeded response: HTTPResponse, request: URLRequest
  ) async throws -> HTTPResponse {
    guard isBusinessUnauthorized(response) else { return response }
    _ = try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request))
    let retry = try await replacingAccessToken(in: request)
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry)
    if second.status == 401 || isBusinessUnauthorized(second) {
      throw OAuthDriveError.loginRequired
    }
    return second
  }

  private func replacingAccessToken(in request: URLRequest) async throws -> URLRequest {
    OAuthRequestToken.replacing(in: request, with: try await session.accessToken())
  }

  private func isBusinessUnauthorized(_ response: HTTPResponse) -> Bool {
    guard (200..<300).contains(response.status),
      let status = try? JSONDecoder().decode(BaiduStatus.self, from: response.body),
      let errno = status.code
    else { return false }
    if case .unauthorized = mapBusiness(errno) { return true }
    return false
  }

  private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
    do {
      if let error = CloudDriveSupport.mapHTTP(response) { throw error }
      if let status = try? JSONDecoder().decode(BaiduStatus.self, from: response.body),
        let errno = status.code, errno != 0
      {
        throw mapBusiness(errno, message: status.message)
      }
      do {
        return try JSONDecoder().decode(type, from: response.body)
      } catch {
        throw RemoteError.protocolError
      }
    } catch {
      if (200..<300).contains(response.status) {
        PackageDiagnostics.failure(error, category: .cloudDrive, operation: .request)
      }
      throw error
    }
  }

  private func checkBaidu(_ response: HTTPResponse) throws {
    do {
      if let error = CloudDriveSupport.mapHTTP(response) { throw error }
      guard let status = try? JSONDecoder().decode(BaiduStatus.self, from: response.body),
        let errno = status.code
      else { throw RemoteError.protocolError }
      if errno != 0 { throw mapBusiness(errno, message: status.message) }
      guard let result = try? JSONDecoder().decode(BaiduFileResult.self, from: response.body) else {
        throw RemoteError.protocolError
      }
      for item in result.info ?? [] where item.errno != 0 { throw mapBusiness(item.errno) }
    } catch {
      if (200..<300).contains(response.status) {
        PackageDiagnostics.failure(error, category: .cloudDrive, operation: .request)
      }
      throw error
    }
  }

  private func makeBlocks(
    file: URL, size: Int64, blockSize: Int64
  ) throws -> (md5: [String], digest: String) {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    var values: [String] = []
    if size == 0 {
      return ([CloudDriveSupport.md5Hex(Data())], CloudDriveSupport.md5Hex(Data()))
    }
    var remaining = size
    while remaining > 0 {
      try Task.checkCancellation()
      let length = min(blockSize, remaining)
      let data = try handle.read(upToCount: Int(length)) ?? Data()
      guard data.count == Int(length) else {
        throw CloudDriveSupport.localShortRead(
          file, offset: size - remaining, expected: length, actual: data.count)
      }
      hasher.update(data: data)
      values.append(CloudDriveSupport.md5Hex(data))
      remaining -= Int64(data.count)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (values, digest)
  }

  private func remotePath(_ path: RemotePath) -> String {
    if configuration.rootPath == "/" { return path.value }
    if path.value == "/" { return configuration.rootPath }
    return configuration.rootPath + path.value
  }

  private func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw RemoteError.protocolError
    }
    return string
  }

  private func mapBusiness(_ code: Int?, message: String? = nil) -> RemoteError {
    switch code {
    case -6, 20016, 20017, 31045:
      return .unauthorized
    case -7, 20020, 31024:
      return .posix(EACCES)
    case -8, 10, 31061:
      return .posix(EEXIST)
    case -9, 31066:
      return .posix(ENOENT)
    case -10, 31190:
      return .posix(ENOSPC)
    case 31034, 42905:
      return .rateLimited
    case 31365:
      return .posix(EFBIG)
    default:
      // 其他错误码照实带上百度网盘的原话
      return CloudDriveSupport.businessFailure(L("百度网盘"), code: code, message: message)
    }
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }
}

private struct BaiduDownloadLink {
  let link: String
  let size: Int64?
  let modified: Int64?
  let fetched: Date
}

private struct BaiduFileResult: Decodable {
  struct Item: Decodable { let errno: Int }
  let info: [Item]?
}

private struct BaiduStatus: Decodable {
  let errno: Int?
  let error_code: Int?
  let errmsg: String?
  let show_msg: String?
  let error_msg: String?
  var code: Int? {
    if let errno, errno != 0 { return errno }
    return error_code ?? errno
  }
  // 百度的说明可能在 errmsg、show_msg 或 error_msg 里，都带上
  var message: String? {
    var parts: [String] = []
    for text in [errmsg, show_msg, error_msg].compactMap({ $0 })
    where !text.isEmpty && !parts.contains(text) {
      parts.append(text)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " / ")
  }
}

private struct BaiduUser: Decodable {
  let uk: UInt64?
  let vip_type: Int?
  let baidu_name: String?
  let netdisk_name: String?
  let avatar_url: String?

  var vipType: Int? { vip_type }
}

private struct BaiduQuota: Decodable {
  let errno: Int?
  let total: Int64
  let used: Int64
}

private struct BaiduListResponse: Decodable {
  struct Nested: Decodable {
    let list: [BaiduItem]?
  }
  let errno: Int?
  let errmsg: String?
  let list: [BaiduItem]?
  let data: Nested?
}

private struct BaiduItem: Decodable {
  let fs_id: UInt64?
  let path: String
  let server_filename: String?
  let filename: String?
  let size: Int64?
  let server_mtime: Int64?
  let isdir: Int?
  let dlink: String?

  func item(root: String) throws -> RemoteItem {
    let logical: String
    if path == root {
      logical = "/"
    } else if root == "/", path.hasPrefix("/") {
      logical = path
    } else if path.hasPrefix(root + "/") {
      logical = String(path.dropFirst(root.count))
    } else {
      throw RemoteError.invalidPath
    }
    let name =
      server_filename ?? filename
      ?? (logical == "/" ? "/" : (logical as NSString).lastPathComponent)
    return RemoteItem(
      path: try RemotePath(logical), name: name, isDirectory: isdir == 1, size: size ?? 0,
      modified: Date(timeIntervalSince1970: TimeInterval(server_mtime ?? 0)))
  }
}

private struct BaiduPrecreate: Decodable {
  let errno: Int?
  let uploadid: String?
  let block_list: [Int]?
  let return_type: Int?
}

private struct BaiduUploadPart: Decodable {
  let md5: String
}

private struct BaiduCreated: Decodable {
  let errno: Int?
  let fs_id: UInt64?
}
