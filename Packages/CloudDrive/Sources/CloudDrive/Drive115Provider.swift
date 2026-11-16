import Core
import CryptoKit
import Foundation

public actor Drive115Provider: RemoteFileProvider, OAuthProfileProviding {
  // 重名文件分到的编号在本次连接里保持不变
  private let duplicateNames = DuplicateNameMemory()
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private let multipartThreshold: Int64
  private let partSize: Int64
  private var connected = false
  // 路径用 Finder 里显示的名字（同名文件编了号），对应到 115 的文件 ID
  private var ids: [String: String] = ["/": "0"]
  private var files: [String: Drive115File] = [:]
  private var downloads: [String: Drive115Download] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  private let now: @Sendable () -> Date
  // 115 不告诉下载地址什么时候过期，短时间内复用，过期或被拒再重新要
  static let downloadLinkLifetime: TimeInterval = 300

  public init(
    session: OAuthSession, transport: any HTTPTransport = URLSessionHTTPTransport(),
    multipartThreshold: Int64 = 4 * 1024 * 1024 * 1024,
    partSize: Int64 = 64 * 1024 * 1024
  ) {
    self.init(
      session: session, transport: transport, multipartThreshold: multipartThreshold,
      partSize: partSize, now: { Date() })
  }

  init(
    session: OAuthSession, transport: any HTTPTransport, multipartThreshold: Int64,
    partSize: Int64, now: @escaping @Sendable () -> Date
  ) {
    self.session = session
    self.transport = session.limited(transport)
    self.multipartThreshold = multipartThreshold
    self.partSize = partSize
    self.now = now
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    _ = try await userInfo()
    connected = true
  }

  public func disconnect() async {
    connected = false
    ids = ["/": "0"]
    files.removeAll()
    downloads.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let value = try await userInfo()
    return SpaceInfo(total: value.total, used: value.used)
  }

  public func profile() async throws -> OAuthProfile {
    let value = try await userInfo()
    return OAuthProfile(
      userID: String(value.userID), nickname: value.userName, avatarURL: value.avatar)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    let parent = try await resolve(path)
    var offset = 0
    var entries: [Drive115ListEntry] = []
    while true {
      let response = try await api(
        "GET", "/open/ufile/files",
        query: [
          URLQueryItem(name: "cid", value: parent),
          URLQueryItem(name: "limit", value: "1150"),
          URLQueryItem(name: "offset", value: String(offset)),
          URLQueryItem(name: "show_dir", value: "1"),
          URLQueryItem(name: "cur", value: "1"),
          URLQueryItem(name: "asc", value: "1"),
          URLQueryItem(name: "o", value: "file_name"),
          URLQueryItem(name: "custom_order", value: "2"),
        ])
      let page = try decode(Drive115ListEnvelope.self, from: response)
      let pageEntries = page.data ?? []
      entries += pageEntries.filter { $0.aid == nil || $0.aid == "1" }
      if let total = page.count {
        guard total >= 0, offset + pageEntries.count <= total else {
          throw RemoteError.protocolError
        }
        if offset + pageEntries.count == total { break }
        guard !pageEntries.isEmpty else { throw RemoteError.protocolError }
      } else if pageEntries.count < 1_150 {
        break
      }
      offset += pageEntries.count
    }
    let names = duplicateNames.assign(
      entries.map { DuplicateNames.Entry(id: $0.fid, name: $0.fn, isDirectory: $0.fc == "0") }, in: path.value)
    forget(under: path)
    var result: [RemoteItem] = []
    var resolved: [String: String] = [:]
    for entry in entries {
      guard let name = names[entry.fid] else { throw RemoteError.protocolError }
      let item = try entry.item(at: path.appending(name))
      result.append(item)
      resolved[item.path.value] = entry.fid
      files[entry.fid] = Drive115File(
        name: entry.fn, pickCode: entry.pc ?? files[entry.fid]?.pickCode, size: item.size,
        modified: item.modified)
    }
    ids[path.value] = parent
    ids.merge(resolved) { $1 }
    return result
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0))
    }
    let info = try await getInfo(path)
    return info.item(path: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    if let range, range.lowerBound < 0 || range.lowerBound > range.upperBound {
      throw RemoteError.posix(EINVAL)
    }
    if range?.isEmpty == true { return CloudDriveSupport.emptyStream() }
    let id = try await resolve(path)
    var file = files[id]
    if file?.pickCode?.isEmpty != false {
      _ = try await getInfo(path)
      file = files[id]
    }
    guard let file, let pickCode = file.pickCode, !pickCode.isEmpty else {
      throw RemoteError.protocolError
    }
    for attempt in 0..<2 {
      let url = try await downloadURL(id: id, file: file, pickCode: pickCode)
      var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
      if let range {
        request.setValue(
          "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
          forHTTPHeaderField: "Range")
      }
      let stream = try await CloudDriveSupport.streamWithRetry(transport, request)
      // 下载地址过期会被拒，换一个新地址再试一次
      if [401, 403].contains(stream.response.status), attempt == 0 {
        downloads.removeValue(forKey: id)
        continue
      }
      if let error = CloudDriveSupport.mapHTTP(stream.response) { throw error }
      if range != nil, stream.response.status != 206 { throw RemoteError.protocolError }
      return stream.body
    }
    throw RemoteError.posix(EACCES)
  }

  private func downloadURL(id: String, file: Drive115File, pickCode: String) async throws -> URL {
    let current = now()
    if let cached = downloads[id], cached.size == file.size, cached.modified == file.modified,
      current.timeIntervalSince(cached.fetched) < Self.downloadLinkLifetime
    {
      return cached.url
    }
    var form = MultipartFormData()
    form.addText("pick_code", pickCode)
    let response = try await sendAPI(
      CloudDriveSupport.multipartRequest(
        try baseURL("/open/ufile/downurl"), form: form,
        headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
    _ = try decode(Drive115EmptyEnvelope.self, from: response)
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let data = object["data"] as? [String: Any]
    else { throw RemoteError.protocolError }
    let rawURL = data.values.compactMap {
      (($0 as? [String: Any])?["url"] as? [String: Any])?["url"] as? String
    }.first
    guard let rawURL, let url = URL(string: rawURL) else {
      throw RemoteError.protocolError
    }
    downloads = downloads.filter {
      current.timeIntervalSince($0.value.fetched) < Self.downloadLinkLifetime
    }
    downloads[id] = Drive115Download(
      url: url, size: file.size, modified: file.modified, fetched: current)
    return url
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
    let parent = try await resolve(CloudDriveSupport.parent(path))
    let hashes = try fileHashes(localFile)
    var fields = [
      "file_name": CloudDriveSupport.basename(path), "file_size": String(size),
      "target": "U_1_\(parent)", "fileid": hashes.sha1, "preid": hashes.preID,
      "topupload": "0", "upload_v2": "1",
    ]
    var prepared = try await initializeUpload(fields: fields)
    if prepared.status == 6 || prepared.status == 7 || prepared.status == 8,
      let range = prepared.signCheck, let signKey = prepared.signKey
    {
      let signed = try hashRange(file: localFile, range: range)
      guard !signed.isEmpty else { throw RemoteError.protocolError }
      fields["sign_key"] = signKey
      fields["sign_val"] = signed
      prepared = try await initializeUpload(fields: fields)
    }
    if prepared.status == 2 { return }
    guard prepared.status == 1, let callback = prepared.callback,
      let object = prepared.object, !object.isEmpty
    else { throw driveError(prepared.code) }
    let credentials = try await uploadCredentials()
    guard let bucket = prepared.bucket, !bucket.isEmpty else {
      throw RemoteError.protocolError
    }
    if size > multipartThreshold {
      try await uploadMultipart(
        file: localFile, size: size, object: object,
        bucket: bucket, credentials: credentials, callback: callback, progress: progress)
    } else {
      try await uploadSingle(
        file: localFile, object: object,
        bucket: bucket, credentials: credentials, callback: callback, progress: progress)
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    try await ensureMissing(path)
    let parent = try await resolve(CloudDriveSupport.parent(path))
    var form = MultipartFormData()
    form.addText("pid", parent)
    form.addText("file_name", CloudDriveSupport.basename(path))
    let response = try await sendAPI(
      CloudDriveSupport.multipartRequest(
        try baseURL("/open/folder/add"), form: form,
        headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
    _ = try decode(Drive115EmptyEnvelope.self, from: response)
    invalidate(from: CloudDriveSupport.parent(path))
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let item = try await stat(path)
    if !recursive, item.isDirectory, try await !list(path).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    let id = try await resolve(path)
    let parent = try await resolve(CloudDriveSupport.parent(path))
    var form = MultipartFormData()
    form.addText("file_ids", id)
    form.addText("parent_id", parent)
    let response = try await sendAPI(
      CloudDriveSupport.multipartRequest(
        try baseURL("/open/ufile/delete"), form: form,
        headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
    _ = try decode(Drive115EmptyEnvelope.self, from: response)
    invalidate(from: path)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    try await ensureMissing(to)
    let sourceID = try await resolve(from)
    let targetID = try await resolve(CloudDriveSupport.parent(to))
    // 同名文件在 Finder 里显示的是编号后的名字，要按网盘上的真实名字判断是否需要改名
    let currentName = files[sourceID]?.name ?? CloudDriveSupport.basename(from)
    var form = MultipartFormData()
    form.addText("file_ids", sourceID)
    form.addText("to_cid", targetID)
    do {
      if CloudDriveSupport.parent(from) != CloudDriveSupport.parent(to) {
        let moved = try await sendAPI(
          CloudDriveSupport.multipartRequest(
            try baseURL("/open/ufile/move"), form: form,
            headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
        _ = try decode(Drive115EmptyEnvelope.self, from: moved)
      }
      if currentName != CloudDriveSupport.basename(to) {
        var rename = MultipartFormData()
        rename.addText("file_id", sourceID)
        rename.addText("file_name", CloudDriveSupport.basename(to))
        let renamed = try await sendAPI(
          CloudDriveSupport.multipartRequest(
            try baseURL("/open/ufile/update"), form: rename,
            headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
        _ = try decode(Drive115EmptyEnvelope.self, from: renamed)
      }
    } catch {
      invalidate(from: from)
      invalidate(from: CloudDriveSupport.parent(to))
      throw error
    }
    invalidate(from: from)
    invalidate(from: CloudDriveSupport.parent(to))
    ids[to.value] = sourceID
    files[sourceID]?.name = CloudDriveSupport.basename(to)
  }

  private func userInfo() async throws -> Drive115UserData {
    let response = try await api("GET", "/open/user/info")
    let envelope = try decode(Drive115UserEnvelope.self, from: response)
    guard let value = envelope.data else { throw RemoteError.protocolError }
    return value
  }

  private func initializeUpload(fields: [String: String]) async throws -> Drive115UploadData {
    var form = MultipartFormData()
    for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
      form.addText(name, value)
    }
    let response = try await sendAPI(
      CloudDriveSupport.multipartRequest(
        try baseURL("/open/upload/init"), form: form,
        headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
    let envelope = try decode(Drive115UploadEnvelope.self, from: response)
    guard let value = envelope.data else { throw RemoteError.protocolError }
    return value
  }

  private func uploadCredentials() async throws -> Drive115Credentials {
    let response = try await api(
      "GET", "/open/upload/get_token",
      query: [URLQueryItem(name: "upload_v2", value: "1")])
    let envelope = try decode(Drive115CredentialsEnvelope.self, from: response)
    guard let value = envelope.data, let endpoint = value.endpoint,
      !value.accessKeyID.isEmpty, !value.accessKeySecret.isEmpty,
      !value.securityToken.isEmpty
    else { throw RemoteError.protocolError }
    return Drive115Credentials(
      endpoint: endpoint, accessKeyID: value.accessKeyID,
      accessKeySecret: value.accessKeySecret, securityToken: value.securityToken,
      rate: value.transferConfig?.rate)
  }

  private func sendUploadRequest(
    credentials: inout Drive115Credentials, bucket: String, upload: Bool = false,
    makeRequest: (Drive115OSSSigner, String) throws -> URLRequest
  ) async throws -> HTTPResponse {
    var request = try makeRequest(Drive115OSSSigner(credentials: credentials, bucket: bucket), credentials.endpoint)
    let response = try await CloudDriveSupport.sendWithRetry(transport, request, upload: upload)
    guard response.status == 403,
      Drive115XML.value("Code", in: response.body) == "SecurityTokenExpired"
    else { return response }
    try Task.checkCancellation()
    credentials = try await uploadCredentials()
    request = try makeRequest(Drive115OSSSigner(credentials: credentials, bucket: bucket), credentials.endpoint)
    return try await CloudDriveSupport.sendWithRetry(transport, request, upload: upload)
  }

  private func uploadSingle(
    file: URL, object: String, bucket: String,
    credentials: Drive115Credentials,
    callback: Drive115Callback, progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    var credentials = credentials
    let response = try await sendUploadRequest(credentials: &credentials, bucket: bucket, upload: true) { signer, endpoint in
      try signer.request(
        method: "PUT", endpoint: endpoint, object: object, body: data,
        callback: callback, contentMD5: Data(Insecure.MD5.hash(data: data)).base64EncodedString())
    }
    try checkUploadResult(response)
    progress?(Int64(data.count), Int64(data.count))
  }

  private func uploadMultipart(
    file: URL, size: Int64, object: String,
    bucket: String, credentials: Drive115Credentials, callback: Drive115Callback,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    guard partSize > 0 else { throw RemoteError.posix(EINVAL) }
    var credentials = credentials
    let started = try await sendUploadRequest(credentials: &credentials, bucket: bucket) { signer, endpoint in
      try signer.request(
        method: "POST", endpoint: endpoint, object: object, body: Data(),
        query: [URLQueryItem(name: "uploads", value: "")], callback: callback)
    }
    if let error = CloudDriveSupport.mapHTTP(started) { throw error }
    guard let uploadID = Drive115XML.value("UploadId", in: started.body), !uploadID.isEmpty else {
      throw RemoteError.protocolError
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var completed: [(Int, String)] = []
    var offset: Int64 = 0
    var number = 1
    do {
      while offset < size {
        try Task.checkCancellation()
        try handle.seek(toOffset: UInt64(offset))
        let length = min(partSize, size - offset)
        guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
          throw RemoteError.posix(EIO)
        }
        let response = try await sendUploadRequest(credentials: &credentials, bucket: bucket, upload: true) { signer, endpoint in
          try signer.request(
            method: "PUT", endpoint: endpoint, object: object, body: data,
            query: [
              URLQueryItem(name: "partNumber", value: String(number)),
              URLQueryItem(name: "uploadId", value: uploadID),
            ], callback: nil,
            contentMD5: Data(Insecure.MD5.hash(data: data)).base64EncodedString())
        }
        if let error = CloudDriveSupport.mapHTTP(response) { throw error }
        guard let etag = response.header("ETag"), !etag.isEmpty else {
          throw RemoteError.protocolError
        }
        completed.append((number, etag))
        offset += Int64(data.count)
        progress?(offset, size)
        number += 1
      }
      let response = try await sendUploadRequest(credentials: &credentials, bucket: bucket) { signer, endpoint in
        try signer.request(
          method: "POST", endpoint: endpoint, object: object,
          body: Drive115XML.complete(parts: completed),
          query: [URLQueryItem(name: "uploadId", value: uploadID)], callback: callback)
      }
      try checkUploadResult(response)
    } catch {
      let signer = Drive115OSSSigner(credentials: credentials, bucket: bucket)
      let request = try signer.request(
        method: "DELETE", endpoint: credentials.endpoint, object: object, body: Data(),
        query: [URLQueryItem(name: "uploadId", value: uploadID)], callback: nil)
      let transport = transport
      let cleanup = Task.detached {
        _ = try? await CloudDriveSupport.sendWithRetry(transport, request)
      }
      await cleanup.value
      throw error
    }
  }

  // 按文件 ID 查，路径里可能是同名文件编号后的显示名
  private func getInfo(_ path: RemotePath) async throws -> Drive115ItemInfo {
    let id = try await resolve(path)
    let response = try await api(
      "GET", "/open/folder/get_info", query: [URLQueryItem(name: "file_id", value: id)])
    let envelope = try decode(Drive115InfoEnvelope.self, from: response)
    guard let value = envelope.data else { throw RemoteError.posix(ENOENT) }
    guard value.fileID == id else { throw RemoteError.protocolError }
    // 在别处被改了名，旧路径已经不对了
    if let known = files[id]?.name, known != value.fileName {
      invalidate(from: CloudDriveSupport.parent(path))
      throw RemoteError.posix(ENOENT)
    }
    let item = value.item(path: path)
    files[id] = Drive115File(
      name: value.fileName, pickCode: value.pickCode ?? files[id]?.pickCode, size: item.size,
      modified: item.modified)
    return value
  }

  private func resolve(_ path: RemotePath) async throws -> String {
    if let value = ids[path.value] { return value }
    _ = try await list(CloudDriveSupport.parent(path))
    guard let value = ids[path.value] else { throw RemoteError.posix(ENOENT) }
    return value
  }

  private func checkUploadResult(_ response: HTTPResponse) throws {
    if let error = CloudDriveSupport.mapHTTP(response) { throw error }
    guard response.status == 200, Drive115XML.value("Code", in: response.body) == nil else {
      throw RemoteError.posix(EIO)
    }
    if let envelope = try? JSONDecoder().decode(Drive115StatusEnvelope.self, from: response.body),
      !envelope.state.isTrue
    {
      throw driveError(envelope.code)
    }
  }

  private func api(
    _ method: String, _ path: String, query: [URLQueryItem] = []
  ) async throws -> HTTPResponse {
    var request = URLRequest(
      url: try CloudDriveSupport.url("https://proapi.115.com" + path, query: query),
      timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = method
    request.setValue(
      "Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
    return try await sendAPI(request)
  }

  private func sendAPI(_ request: URLRequest) async throws -> HTTPResponse {
    let first = try await CloudDriveSupport.sendWithRetry(transport, request)
    guard first.status == 401 || isUnauthorized(first) else { return first }
    var retry = request
    retry.setValue(
      "Bearer \(try await session.refreshNow(rejectedAccessToken: OAuthRequestToken.read(from: request)))",
      forHTTPHeaderField: "Authorization")
    let second = try await CloudDriveSupport.sendWithRetry(transport, retry)
    if second.status == 401 || isUnauthorized(second) {
      throw OAuthDriveError.loginRequired
    }
    return second
  }

  private func isUnauthorized(_ response: HTTPResponse) -> Bool {
    guard (200..<300).contains(response.status),
      let value = try? JSONDecoder().decode(Drive115StatusEnvelope.self, from: response.body),
      !value.state.isTrue, let code = value.code
    else { return false }
    if case .unauthorized = driveError(code) { return true }
    return false
  }

  private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
    do {
      if let error = CloudDriveSupport.mapHTTP(response) { throw error }
      do {
        let value = try JSONDecoder().decode(type, from: response.body)
        if let envelope = value as? Drive115Stateful, !envelope.success {
          throw driveError(envelope.businessCode)
        }
        return value
      } catch let error as RemoteError {
        throw error
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

  private func baseURL(_ path: String) throws -> URL {
    try CloudDriveSupport.url("https://proapi.115.com" + path)
  }

  // 清掉目录下所有路径的缓存，文件信息跟着路径一起清
  private func forget(under path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    for (key, id) in ids where key.hasPrefix(prefix) { files[id] = nil }
    ids = ids.filter { !$0.key.hasPrefix(prefix) }
  }

  private func invalidate(from path: RemotePath) {
    forget(under: path)
    if let id = ids.removeValue(forKey: path.value) { files[id] = nil }
    ids["/"] = "0"
  }

  private func fileHashes(_ url: URL) throws -> (sha1: String, preID: String) {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return (
      CloudDriveSupport.sha1Hex(data),
      CloudDriveSupport.sha1Hex(Data(data.prefix(128 * 1024)))
    )
  }

  private func hashRange(file: URL, range: String) throws -> String {
    let bounds = range.split(separator: "-").compactMap { Int64($0) }
    guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0] else {
      throw RemoteError.protocolError
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(bounds[0]))
    guard let data = try handle.read(upToCount: Int(bounds[1] - bounds[0] + 1)) else {
      throw RemoteError.posix(EIO)
    }
    return CloudDriveSupport.sha1Hex(data, uppercase: true)
  }

  private func driveError(_ code: Int?) -> RemoteError {
    switch code {
    case 40_140_116, 40_140_119, 40_140_120, 40_140_125, 40_140_126, 40_140_137, 40_140_127:
      return .unauthorized
    case 20009, 20018:
      return .posix(ENOENT)
    case 990001:
      return .posix(EEXIST)
    case 40_140_117:
      return .rateLimited
    default:
      return .protocolError
    }
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }
}

private protocol Drive115Stateful {
  var success: Bool { get }
  var businessCode: Int? { get }
}

private enum Drive115Bool: Decodable {
  case bool(Bool)
  case integer(Int)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else {
      self = .integer(try container.decode(Int.self))
    }
  }

  var isTrue: Bool {
    switch self {
    case .bool(let value): value
    case .integer(let value): value != 0
    }
  }
}

private struct Drive115StatusEnvelope: Decodable {
  let state: Drive115Bool
  let code: Int?
}

private struct Drive115UserEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  let data: Drive115UserData?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115UserData: Decodable {
  struct Space: Decodable {
    let size: Int64?
  }
  struct Detail: Decodable {
    let size: Int64
  }
  struct SpaceInfo: Decodable {
    let allTotal: Space?
    let allUse: Space?
    enum CodingKeys: String, CodingKey {
      case allTotal = "all_total"
      case allUse = "all_use"
    }
  }
  let userID: Int64
  let userName: String
  let avatar: String?
  let rtSpaceInfo: SpaceInfo?
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case userName = "user_name"
    case avatar = "user_face_m"
    case rtSpaceInfo = "rt_space_info"
  }
  var total: Int64? { rtSpaceInfo?.allTotal?.size }
  var used: Int64? { rtSpaceInfo?.allUse?.size }
}

private struct Drive115ListEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  let data: [Drive115ListEntry]?
  let count: Int?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115ListEntry: Decodable {
  let fid: String
  let aid: String?
  let fc: String
  let fn: String
  let upt: Int64?
  let uet: Int64?
  let fs: Int64?
  let pc: String?
  func item(at path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: path.basename, isDirectory: fc == "0", size: fs ?? 0,
      modified: Date(timeIntervalSince1970: TimeInterval(uet ?? upt ?? 0)))
  }
}

private struct Drive115File {
  var name: String
  let pickCode: String?
  let size: Int64
  let modified: Date
}

private struct Drive115Download {
  let url: URL
  let size: Int64
  let modified: Date
  let fetched: Date
}

private struct Drive115InfoEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  let data: Drive115ItemInfo?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115ItemInfo: Decodable {
  let fileID: String
  let fileName: String
  let category: String
  let sizeByte: Int64?
  let utime: String?
  let pickCode: String?
  enum CodingKeys: String, CodingKey {
    case fileID = "file_id"
    case fileName = "file_name"
    case category = "file_category"
    case sizeByte = "size_byte"
    case utime
    case pickCode = "pick_code"
  }
  func item(path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: path.basename, isDirectory: category == "0", size: sizeByte ?? 0,
      modified: CloudDriveSupport.parseDate(utime))
  }
}

private struct Drive115EmptyEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115UploadEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  let data: Drive115UploadData?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115UploadData: Decodable {
  let status: Int
  let code: Int?
  let endpoint: String?
  let bucket: String?
  let object: String?
  let callback: Drive115Callback?
  let signKey: String?
  let signCheck: String?
  enum CodingKeys: String, CodingKey {
    case status, code, endpoint, bucket, object, callback
    case signKey = "sign_key"
    case signCheck = "sign_check"
  }
}

struct Drive115Callback: Decodable {
  let callback: String
  let callbackVar: String
  enum CodingKeys: String, CodingKey {
    case callback
    case callbackVar = "callback_var"
  }
}

private struct Drive115CredentialsEnvelope: Decodable, Drive115Stateful {
  let state: Drive115Bool
  let code: Int?
  let data: Drive115CredentialsValue?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
}

private struct Drive115CredentialsValue: Decodable {
  struct TransferConfig: Decodable {
    let rate: Int?
  }
  let endpoint: String?
  let accessKeyID: String
  let accessKeySecret: String
  let securityToken: String
  let transferConfig: TransferConfig?
  enum CodingKeys: String, CodingKey {
    case endpoint
    case accessKeyID = "AccessKeyId"
    case accessKeySecret = "AccessKeySecret"
    case securityToken = "SecurityToken"
    case transferConfig = "transfer_config"
  }
}

struct Drive115Credentials {
  let endpoint: String
  let accessKeyID: String
  let accessKeySecret: String
  let securityToken: String
  let rate: Int?
}

struct Drive115OSSSigner {
  let credentials: Drive115Credentials
  let bucket: String

  func request(
    method: String, endpoint: String, object: String, body: Data,
    query: [URLQueryItem] = [], callback: Drive115Callback?, contentMD5: String? = nil,
    now: Date = Date()
  ) throws -> URLRequest {
    let address = endpoint.contains("://") ? endpoint : "https://" + endpoint
    guard var components = URLComponents(string: address),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let endpointHost = components.host, !endpointHost.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/",
      !bucket.isEmpty,
      !bucket.contains(where: { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "-") })
    else { throw RemoteError.protocolError }
    components.scheme = "https"
    if components.port == 80 { components.port = nil }
    if !endpointHost.lowercased().hasPrefix(bucket.lowercased() + ".") {
      components.host = bucket + "." + endpointHost
    }
    let encodedObject = object.split(separator: "/", omittingEmptySubsequences: false)
      .map { CloudDriveSupport.encode(String($0)) }.joined(separator: "/")
    components.percentEncodedPath = "/" + encodedObject
    let sortedQuery = query.sorted {
      $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
    }
    components.percentEncodedQuery =
      sortedQuery.isEmpty
      ? nil
      : sortedQuery.map {
        CloudDriveSupport.encode($0.name) + "=" + CloudDriveSupport.encode($0.value ?? "")
      }.joined(separator: "&")
    guard let url = components.url, let host = components.host else {
      throw RemoteError.protocolError
    }
    let date = Self.rfc1123(now)
    let contentType = "application/octet-stream"
    var headers = [
      "Date": date,
      "Content-Type": contentType,
      "Host": host,
      "x-oss-security-token": credentials.securityToken,
    ]
    if let contentMD5 { headers["Content-MD5"] = contentMD5 }
    if let callback {
      headers["x-oss-callback"] = Data(callback.callback.utf8).base64EncodedString()
      headers["x-oss-callback-var"] = Data(callback.callbackVar.utf8).base64EncodedString()
    }
    if let rate = credentials.rate, rate > 0 {
      headers["x-oss-traffic-limit"] = String(rate * 8)
    }
    let ossHeaders = headers.filter { $0.key.lowercased().hasPrefix("x-oss-") }
      .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .sorted { $0.0 < $1.0 }
      .map { "\($0.0):\($0.1)\n" }.joined()
    let subresources = sortedQuery.map {
      $0.name + (($0.value ?? "").isEmpty ? "" : "=" + $0.value!)
    }.joined(separator: "&")
    let bucketPath = "/\(bucket)/\(object)" + (subresources.isEmpty ? "" : "?" + subresources)
    let stringToSign = [
      method, headers["Content-MD5"] ?? "", contentType, date, ossHeaders + bucketPath,
    ].joined(separator: "\n")
    let signature = Self.hmacSHA1(
      key: Data(credentials.accessKeySecret.utf8), message: Data(stringToSign.utf8))
    headers["Authorization"] = "OSS \(credentials.accessKeyID):\(signature)"
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
    request.httpMethod = method
    request.httpBody = body.isEmpty ? nil : body
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  private static func rfc1123(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }

  private static func hmacSHA1(key: Data, message: Data) -> String {
    Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
      .base64EncodedString()
  }
}

private enum Drive115XML {
  static func value(_ name: String, in data: Data) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    guard let start = text.range(of: "<\(name)>"),
      let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex)
    else { return nil }
    return String(text[start.upperBound..<end.lowerBound])
  }

  static func complete(parts: [(Int, String)]) -> Data {
    let values = parts.map {
      "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>"
    }.joined()
    return Data("<CompleteMultipartUpload>\(values)</CompleteMultipartUpload>".utf8)
  }
}
