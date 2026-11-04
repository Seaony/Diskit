import Core
import CryptoKit
import Foundation

public actor Drive115Provider: RemoteFileProvider, OAuthProfileProviding {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private let multipartThreshold: Int64
  private let partSize: Int64
  private var connected = false
  private var ids: [String: String] = ["/": "0"]
  private var cachedSpace = SpaceInfo(total: 0, used: 0)
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: OAuthSession, transport: any HTTPTransport = URLSessionHTTPTransport(),
    multipartThreshold: Int64 = 4 * 1024 * 1024 * 1024,
    partSize: Int64 = 64 * 1024 * 1024
  ) {
    self.session = session
    self.transport = transport
    self.multipartThreshold = multipartThreshold
    self.partSize = partSize
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    let value = try await userInfo()
    cachedSpace = SpaceInfo(total: value.total, used: value.used)
    connected = true
  }

  public func disconnect() async {
    connected = false
    ids = ["/": "0"]
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    return cachedSpace
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
    var result: [RemoteItem] = []
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
      let entries = page.data ?? []
      for entry in entries where entry.aid == nil || entry.aid == "1" {
        let item = try entry.item(parent: path)
        result.append(item)
        ids[item.path.value] = entry.fid
      }
      guard entries.count > 0, result.count < (page.count ?? result.count),
        entries.count == 1_150
      else { break }
      offset += entries.count
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
    let info = try await getInfo(path)
    ids[path.value] = info.fileID
    return try info.item(path: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    if let range, range.lowerBound < 0 || range.lowerBound > range.upperBound {
      throw RemoteError.posix(EINVAL)
    }
    if range?.isEmpty == true { return CloudDriveSupport.emptyStream() }
    let info = try await getInfo(path)
    guard let pickCode = info.pickCode, !pickCode.isEmpty else {
      throw RemoteError.protocolError
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
    var request = URLRequest(url: url, timeoutInterval: 60)
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))",
        forHTTPHeaderField: "Range")
    }
    let stream = try await CloudDriveSupport.streamWithRetry(transport, request)
    if let error = CloudDriveSupport.mapHTTP(stream.response) { throw error }
    if range != nil, stream.response.status != 206 { throw RemoteError.protocolError }
    return stream.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
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
    let endpoint = prepared.endpoint ?? credentials.endpoint
    guard let bucket = prepared.bucket, !bucket.isEmpty else {
      throw RemoteError.protocolError
    }
    if size > multipartThreshold {
      try await uploadMultipart(
        file: localFile, size: size, endpoint: endpoint, object: object,
        bucket: bucket, credentials: credentials, callback: callback)
    } else {
      try await uploadSingle(
        file: localFile, endpoint: endpoint, object: object,
        bucket: bucket, credentials: credentials, callback: callback)
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
    var form = MultipartFormData()
    form.addText("file_ids", sourceID)
    form.addText("to_cid", targetID)
    do {
      let moved = try await sendAPI(
        CloudDriveSupport.multipartRequest(
          try baseURL("/open/ufile/move"), form: form,
          headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
      _ = try decode(Drive115EmptyEnvelope.self, from: moved)
      if CloudDriveSupport.basename(from) != CloudDriveSupport.basename(to) {
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

  private func uploadSingle(
    file: URL, endpoint: String, object: String, bucket: String,
    credentials: Drive115Credentials,
    callback: Drive115Callback
  ) async throws {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    let signer = Drive115OSSSigner(credentials: credentials, bucket: bucket)
    let request = try signer.request(
      method: "PUT", endpoint: endpoint, object: object, body: data,
      callback: callback, contentMD5: Data(Insecure.MD5.hash(data: data)).base64EncodedString())
    let response = try await CloudDriveSupport.sendWithRetry(transport, request)
    if let error = CloudDriveSupport.mapHTTP(response) { throw error }
    progress?(Int64(data.count), Int64(data.count))
  }

  private func uploadMultipart(
    file: URL, size: Int64, endpoint: String, object: String,
    bucket: String, credentials: Drive115Credentials, callback: Drive115Callback
  ) async throws {
    let signer = Drive115OSSSigner(credentials: credentials, bucket: bucket)
    let initiate = try signer.request(
      method: "POST", endpoint: endpoint, object: object, body: Data(),
      query: [URLQueryItem(name: "uploads", value: "")],
      callback: callback)
    let started = try await CloudDriveSupport.sendWithRetry(transport, initiate)
    if let error = CloudDriveSupport.mapHTTP(started) { throw error }
    guard let uploadID = Drive115XML.value("UploadId", in: started.body) else {
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
        guard let data = try handle.read(upToCount: Int(length)) else {
          throw RemoteError.posix(EIO)
        }
        let request = try signer.request(
          method: "PUT", endpoint: endpoint, object: object, body: data,
          query: [
            URLQueryItem(name: "partNumber", value: String(number)),
            URLQueryItem(name: "uploadId", value: uploadID),
          ], callback: nil,
          contentMD5: Data(Insecure.MD5.hash(data: data)).base64EncodedString())
        let response = try await CloudDriveSupport.sendWithRetry(transport, request)
        if let error = CloudDriveSupport.mapHTTP(response) { throw error }
        guard let etag = response.header("ETag"), !etag.isEmpty else {
          throw RemoteError.protocolError
        }
        completed.append((number, etag))
        offset += Int64(data.count)
        progress?(offset, size)
        number += 1
      }
      let complete = try signer.request(
        method: "POST", endpoint: endpoint, object: object,
        body: Drive115XML.complete(parts: completed),
        query: [URLQueryItem(name: "uploadId", value: uploadID)],
        callback: callback)
      let response = try await CloudDriveSupport.sendWithRetry(transport, complete)
      if let error = CloudDriveSupport.mapHTTP(response) { throw error }
    } catch {
      let request = try signer.request(
        method: "DELETE", endpoint: endpoint, object: object, body: Data(),
        query: [URLQueryItem(name: "uploadId", value: uploadID)], callback: nil)
      let transport = transport
      let cleanup = Task.detached {
        _ = try? await CloudDriveSupport.sendWithRetry(transport, request)
      }
      await cleanup.value
      throw error
    }
  }

  private func getInfo(_ path: RemotePath) async throws -> Drive115ItemInfo {
    var form = MultipartFormData()
    form.addText("path", path.value)
    let response = try await sendAPI(
      CloudDriveSupport.multipartRequest(
        try baseURL("/open/folder/get_info"), form: form,
        headers: ["Authorization": "Bearer \(try await session.accessToken())"]))
    let envelope = try decode(Drive115InfoEnvelope.self, from: response)
    guard let value = envelope.data else { throw RemoteError.posix(ENOENT) }
    return value
  }

  private func resolve(_ path: RemotePath) async throws -> String {
    if let value = ids[path.value] { return value }
    if path.value == "/" { return "0" }
    let value = try await getInfo(path)
    ids[path.value] = value.fileID
    return value.fileID
  }

  private func api(
    _ method: String, _ path: String, query: [URLQueryItem] = []
  ) async throws -> HTTPResponse {
    var request = URLRequest(
      url: try CloudDriveSupport.url("https://proapi.115.com" + path, query: query),
      timeoutInterval: 60)
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
      "Bearer \(try await session.refreshNow())", forHTTPHeaderField: "Authorization")
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
  }

  private func baseURL(_ path: String) throws -> URL {
    try CloudDriveSupport.url("https://proapi.115.com" + path)
  }

  private func invalidate(from path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    ids = ids.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
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
    let size: Int64
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
  let rtSpaceInfo: SpaceInfo
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case userName = "user_name"
    case avatar = "user_face_m"
    case rtSpaceInfo = "rt_space_info"
  }
  var total: Int64 { rtSpaceInfo.allTotal?.size ?? 0 }
  var used: Int64 { rtSpaceInfo.allUse?.size ?? 0 }
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
  func item(parent: RemotePath) throws -> RemoteItem {
    RemoteItem(
      path: try parent.appending(fn), name: fn, isDirectory: fc == "0", size: fs ?? 0,
      modified: Date(timeIntervalSince1970: TimeInterval(uet ?? upt ?? 0)))
  }
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
  func item(path: RemotePath) throws -> RemoteItem {
    RemoteItem(
      path: path, name: fileName, isDirectory: category == "0", size: sizeByte ?? 0,
      modified: CloudDriveSupport.parseDate(utime))
  }
}

private struct Drive115DownloadEnvelope: Decodable, Drive115Stateful {
  struct Download: Decodable {
    struct URLValue: Decodable { let url: String }
    let url: URLValue?
  }
  let state: Drive115Bool
  let code: Int?
  let data: [String: Download]?
  var success: Bool { state.isTrue }
  var businessCode: Int? { code }
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

private struct Drive115Callback: Decodable {
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

private struct Drive115Credentials {
  let endpoint: String
  let accessKeyID: String
  let accessKeySecret: String
  let securityToken: String
  let rate: Int?
}

private struct Drive115OSSSigner {
  let credentials: Drive115Credentials
  let bucket: String

  func request(
    method: String, endpoint: String, object: String, body: Data,
    query: [URLQueryItem] = [], callback: Drive115Callback?, contentMD5: String? = nil
  ) throws -> URLRequest {
    guard var components = URLComponents(string: endpoint) else {
      throw RemoteError.protocolError
    }
    let encodedObject =
      object.split(separator: "/", omittingEmptySubsequences: true)
      .map { CloudDriveSupport.encode(String($0)) }.joined(separator: "/")
    components.percentEncodedPath = "/" + encodedObject
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url, let host = components.host else {
      throw RemoteError.protocolError
    }
    let date = Self.rfc1123(Date())
    let contentType = "application/octet-stream"
    var headers = [
      "Date": date,
      "Content-Type": contentType,
      "Host": host,
      "x-oss-security-token": credentials.securityToken,
    ]
    if let contentMD5 { headers["Content-MD5"] = contentMD5 }
    if let callback {
      headers["x-oss-callback"] = callback.callback
      headers["x-oss-callback-var"] = callback.callbackVar
    }
    if let rate = credentials.rate, rate > 0 {
      headers["x-oss-traffic-limit"] = String(rate * 8)
    }
    let ossHeaders = headers.filter { $0.key.lowercased().hasPrefix("x-oss-") }
      .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .sorted { $0.0 < $1.0 }
      .map { "\($0.0):\($0.1)\n" }.joined()
    let bucketPath = "/\(bucket)/\(encodedObject)"
    let stringToSign = [
      method, headers["Content-MD5"] ?? "", contentType, date, ossHeaders + bucketPath,
    ].joined(separator: "\n")
    let signature = Self.hmacSHA1(
      key: Data(credentials.accessKeySecret.utf8), message: Data(stringToSign.utf8))
    headers["Authorization"] = "OSS \(credentials.accessKeyID):\(signature)"
    var request = URLRequest(url: url, timeoutInterval: 120)
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
