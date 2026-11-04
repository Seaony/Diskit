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
  private var downloadLinks: [String: String] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    configuration: BaiduDriveConfiguration, session: OAuthSession,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.configuration = configuration
    self.session = session
    self.transport = transport
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
    downloadLinks = [:]
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
      nickname: value.netdisk_name ?? value.baidu_name ?? "百度网盘",
      avatarURL: value.avatar_url)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    let directory = remotePath(path)
    var start = 0
    var result: [RemoteItem] = []
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
      let entries = page.list ?? page.data?.list ?? []
      for entry in entries {
        let item = try entry.item(root: configuration.rootPath)
        result.append(item)
        if let link = entry.dlink { downloadLinks[item.path.value] = link }
      }
      guard entries.count == 1_000 else { break }
      start += entries.count
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
    let item = try await metadata(path, download: false)
    if let link = item.dlink { downloadLinks[path.value] = link }
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
    let metadata = try await metadata(path, download: true)
    guard let rawLink = metadata.dlink else { throw RemoteError.protocolError }
    let token = try await session.accessToken()
    guard var components = URLComponents(string: rawLink) else {
      throw RemoteError.protocolError
    }
    components.queryItems =
      (components.queryItems ?? []) + [URLQueryItem(name: "access_token", value: token)]
    guard let url = components.url else { throw RemoteError.protocolError }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
        forHTTPHeaderField: "Range")
    }
    let response = try await CloudDriveSupport.streamWithRetry(transport, request)
    if let error = CloudDriveSupport.mapHTTP(response.response) { throw error }
    if range != nil, response.response.status != 206 { throw RemoteError.protocolError }
    return response.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let target = remotePath(path)
    try await ensureMissing(path)
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw RemoteError.posix(EIO)
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
    guard let uploadID = prepared.uploadid, !uploadID.isEmpty else {
      throw RemoteError.protocolError
    }
    let locate = try await request(
      method: "GET", path: "/rest/2.0/pcs/file",
      query: [
        URLQueryItem(name: "method", value: "locateupload"),
        URLQueryItem(name: "appid", value: configuration.appID),
        URLQueryItem(name: "path", value: target),
        URLQueryItem(name: "uploadid", value: uploadID),
        URLQueryItem(name: "upload_version", value: "2.0"),
      ])
    let uploadHost = try decodeUploadHost(locate)
    let parts = prepared.block_list?.isEmpty == false ? prepared.block_list! : [0]
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    var uploaded: Int64 = 0
    for part in parts {
      try Task.checkCancellation()
      let offset = Int64(part) * blockSize
      try handle.seek(toOffset: UInt64(offset))
      let length = min(blockSize, size - offset)
      guard let data = try handle.read(upToCount: Int(length)) else {
        throw RemoteError.posix(EIO)
      }
      var form = MultipartFormData()
      form.addFile("file", filename: "part-\(part)", data: data)
      let url = try CloudDriveSupport.url(
        uploadHost + "/rest/2.0/pcs/superfile2",
        query: [
          URLQueryItem(name: "method", value: "upload"),
          URLQueryItem(name: "type", value: "tmpfile"),
          URLQueryItem(name: "path", value: target),
          URLQueryItem(name: "uploadid", value: uploadID),
          URLQueryItem(name: "partseq", value: String(part)),
        ])
      var uploadRequest = CloudDriveSupport.multipartRequest(
        url, form: form, headers: ["User-Agent": "pan.baidu.com"])
      uploadRequest.setValue(
        "Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
      let partResponse = try await upload(uploadRequest)
      try checkBaidu(partResponse, allowMissingErrno: true)
      uploaded += Int64(data.count)
      progress?(uploaded, size)
    }
    let created = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [URLQueryItem(name: "method", value: "create")],
      fields: [
        "path": target, "size": String(size), "isdir": "0", "block_list": blockJSON,
        "uploadid": uploadID, "rtype": "0",
      ])
    let done = try decode(BaiduCreated.self, from: created)
    guard done.errno == 0, done.fs_id != nil else {
      throw mapBusiness(done.errno)
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
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
    let response = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [
        URLQueryItem(name: "method", value: "filemanager"),
        URLQueryItem(name: "opera", value: "delete"),
      ],
      fields: ["async": "0", "filelist": entries])
    try checkBaidu(response)
    downloadLinks.removeValue(forKey: path.value)
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
    let response = try await request(
      method: "POST", path: "/rest/2.0/xpan/file",
      query: [
        URLQueryItem(name: "method", value: "filemanager"),
        URLQueryItem(name: "opera", value: "move"),
      ],
      fields: ["async": "0", "filelist": entries, "ondup": "fail"])
    try checkBaidu(response)
    downloadLinks.removeValue(forKey: from.value)
  }

  private func metadata(_ path: RemotePath, download: Bool) async throws -> BaiduItem {
    let response = try await request(
      method: "GET", path: "/rest/2.0/xpan/file",
      query: [
        URLQueryItem(name: "method", value: "meta"),
        URLQueryItem(name: "path", value: remotePath(path)),
        URLQueryItem(name: "dlink", value: download ? "1" : "0"),
      ])
    let value = try decode(BaiduListResponse.self, from: response)
    let items = value.list ?? value.data?.list ?? []
    guard let item = items.first else {
      throw RemoteError.posix(ENOENT)
    }
    guard items.count == 1 else { throw RemoteError.posix(EEXIST) }
    return item
  }

  private func request(
    method: String, path: String, query: [URLQueryItem] = [], fields: [String: String] = [:]
  ) async throws -> HTTPResponse {
    let base = try CloudDriveSupport.url("https://pan.baidu.com" + path)
    if method == "GET" {
      var request = URLRequest(
        url: try CloudDriveSupport.url(
          "https://pan.baidu.com" + path,
          query: query + [
            URLQueryItem(name: "access_token", value: try await session.accessToken())
          ]),
        timeoutInterval: 60)
      request.httpMethod = method
      request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
      return try await retryBusinessAuthentication(
        ifNeeded: try await authorized(request), request: request)
    }
    var parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    parameters.merge(fields) { _, new in new }
    parameters["access_token"] = try await session.accessToken()
    let request = CloudDriveSupport.formRequest(
      base, method: method, fields: parameters, headers: ["User-Agent": "pan.baidu.com"])
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
    let first = try await CloudDriveSupport.sendWithRetry(transport, request)
    guard first.status == 401 || isBusinessUnauthorized(first) else { return first }
    _ = try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request))
    let retry = try await replacingAccessToken(in: request)
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry)
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
      let errno = status.errno
    else { return false }
    if case .unauthorized = mapBusiness(errno) { return true }
    return false
  }

  private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
    if let error = CloudDriveSupport.mapHTTP(response) { throw error }
    if let status = try? JSONDecoder().decode(BaiduStatus.self, from: response.body),
      let errno = status.errno, errno != 0
    {
      throw mapBusiness(errno)
    }
    do {
      return try JSONDecoder().decode(type, from: response.body)
    } catch {
      throw RemoteError.protocolError
    }
  }

  private func checkBaidu(_ response: HTTPResponse, allowMissingErrno: Bool = false) throws {
    if let error = CloudDriveSupport.mapHTTP(response) { throw error }
    guard let status = try? JSONDecoder().decode(BaiduStatus.self, from: response.body) else {
      if allowMissingErrno { return }
      throw RemoteError.protocolError
    }
    if let errno = status.errno, errno != 0 { throw mapBusiness(errno) }
  }

  private func decodeUploadHost(_ response: HTTPResponse) throws -> String {
    let value = try decode(BaiduUploadHost.self, from: response)
    let host = value.host ?? value.servers?.first?.server
    guard var host else { throw RemoteError.protocolError }
    if !host.hasPrefix("http://"), !host.hasPrefix("https://") {
      host = "https://" + host
    }
    return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
      guard let data = try handle.read(upToCount: Int(length)), !data.isEmpty else {
        throw RemoteError.posix(EIO)
      }
      hasher.update(data: data)
      values.append(CloudDriveSupport.md5Hex(data))
      remaining -= Int64(data.count)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (values, digest)
  }

  private func remotePath(_ path: RemotePath) -> String {
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

  private func mapBusiness(_ code: Int?) -> RemoteError {
    switch code {
    case -6, 20016, 20017, 31045:
      return .unauthorized
    case -7, 20020, 31024:
      return .posix(EACCES)
    case -8, 10, 31061:
      return .posix(EEXIST)
    case -9, 31066, 31190:
      return .posix(ENOENT)
    case -10:
      return .posix(ENOSPC)
    case 20012, 31034:
      return .posix(EIO)
    case 42905:
      return .rateLimited
    case 31365:
      return .posix(EFBIG)
    default:
      return .protocolError
    }
  }

  private func ensureMissing(_ path: RemotePath) async throws {
    do {
      _ = try await stat(path)
      throw RemoteError.posix(EEXIST)
    } catch {
      guard CloudDriveSupport.isExplicitlyMissing(error) else { throw error }
    }
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }
}

private struct BaiduStatus: Decodable {
  let errno: Int?
  let errmsg: String?
  let show_msg: String?
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
}

private struct BaiduCreated: Decodable {
  let errno: Int?
  let fs_id: UInt64?
}

private struct BaiduUploadHost: Decodable {
  struct Server: Decodable {
    let server: String
  }
  let error_code: Int?
  let host: String?
  let servers: [Server]?
}
