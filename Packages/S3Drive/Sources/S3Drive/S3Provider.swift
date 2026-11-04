import Core
import CryptoKit
import Foundation

public struct S3Configuration: Sendable, Equatable {
  public let endpoint: URL
  public let region: String
  public let bucket: String
  public let accessKey: String
  public let secretKey: String
  public let pathStyle: Bool
  public init(
    endpoint: URL, region: String, bucket: String, accessKey: String, secretKey: String,
    pathStyle: Bool = true
  ) {
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.pathStyle = pathStyle
  }
}

public struct S3PresetAddressing: Sendable, Equatable {
  public let endpoint: URL
  public let region: String
  public let pathStyle: Bool
  public init(endpoint: URL, region: String, pathStyle: Bool) {
    self.endpoint = endpoint
    self.region = region
    self.pathStyle = pathStyle
  }
}

public enum S3ServicePreset: String, CaseIterable, Sendable {
  case amazonS3
  case cloudflareR2
  case aliyunOSS
  case tencentCOS
  case qiniuKodo
  case minIO
  case backblazeB2

  public var defaultRegion: String {
    switch self {
    case .amazonS3, .minIO: "us-east-1"
    case .cloudflareR2: "auto"
    case .aliyunOSS: "cn-hangzhou"
    case .tencentCOS: "ap-guangzhou"
    case .qiniuKodo: "cn-east-1"
    case .backblazeB2: "us-west-004"
    }
  }

  public var pathStyle: Bool {
    switch self {
    case .minIO, .backblazeB2: true
    case .amazonS3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo: false
    }
  }

  public func addressing(
    accountID: String? = nil, region: String? = nil, customEndpoint: URL? = nil
  ) throws -> S3PresetAddressing {
    let region = (region ?? defaultRegion).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !region.isEmpty, !region.contains(where: \.isWhitespace) else {
      throw S3PresetError.invalidRegion
    }
    if let customEndpoint {
      guard customEndpoint.host != nil else { throw S3PresetError.invalidEndpoint }
      return S3PresetAddressing(endpoint: customEndpoint, region: region, pathStyle: pathStyle)
    }
    let host: String
    switch self {
    case .amazonS3: host = "s3.\(region).amazonaws.com"
    case .cloudflareR2:
      guard let accountID,
        !accountID.isEmpty,
        !accountID.contains(where: { $0.isWhitespace || $0 == "/" })
      else { throw S3PresetError.missingAccountID }
      host = "\(accountID).r2.cloudflarestorage.com"
    case .aliyunOSS: host = "s3.oss-\(region).aliyuncs.com"
    case .tencentCOS: host = "cos.\(region).myqcloud.com"
    case .qiniuKodo: host = "s3.\(region).qiniucs.com"
    case .minIO: throw S3PresetError.customEndpointRequired
    case .backblazeB2: host = "s3.\(region).backblazeb2.com"
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    guard let endpoint = components.url else { throw S3PresetError.invalidEndpoint }
    return S3PresetAddressing(endpoint: endpoint, region: region, pathStyle: pathStyle)
  }

  public func configuration(
    bucket: String, accessKey: String, secretKey: String, accountID: String? = nil,
    region: String? = nil, customEndpoint: URL? = nil
  ) throws -> S3Configuration {
    let addressing = try addressing(
      accountID: accountID, region: region, customEndpoint: customEndpoint)
    return S3Configuration(
      endpoint: addressing.endpoint, region: addressing.region, bucket: bucket,
      accessKey: accessKey, secretKey: secretKey, pathStyle: addressing.pathStyle)
  }
}

public enum S3PresetError: Error, Equatable, Sendable {
  case missingAccountID, customEndpointRequired, invalidRegion, invalidEndpoint
}

public actor S3Provider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private let configuration: S3Configuration
  private let transport: any HTTPTransport
  private let multipartThreshold: Int64
  private let partSize: Int64
  private var connected = false
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    configuration: S3Configuration, transport: any HTTPTransport = URLSessionHTTPTransport(),
    multipartThreshold: Int64 = 64 * 1024 * 1024, partSize: Int64 = 16 * 1024 * 1024
  ) {
    self.configuration = configuration
    let host = configuration.endpoint.host?.lowercased() ?? ""
    let port = configuration.endpoint.port ?? 443
    let account = "s3:\(host):\(port)|\(configuration.accessKey)"
    self.transport = LimitedHTTPTransport(transport, limit: .shared(for: account))
    self.multipartThreshold = multipartThreshold
    self.partSize = partSize
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    guard configuration.endpoint.scheme == "https", configuration.endpoint.host != nil,
      !configuration.region.isEmpty, !configuration.bucket.isEmpty,
      !configuration.accessKey.isEmpty, !configuration.secretKey.isEmpty
    else { throw RemoteError.posix(EINVAL) }
    connected = true
  }

  public func disconnect() async {
    connected = false
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try ensureConnected()
    let request = try signedRequest(method: "HEAD", path: "")
    try check(try await transport.send(request), allowing: [200])
    return SpaceInfo(total: 0, used: 0)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try ensureConnected()
    let prefix = objectKey(path, directory: path.value != "/")
    let listing = try await listAll(prefix: prefix, delimiter: "/")
    var items: [String: RemoteItem] = [:]
    for key in listing.prefixes where key != prefix {
      let item = try item(
        key: key, size: 0, date: Date(timeIntervalSince1970: 0), directory: true)
      items["dir:\(item.path.value)"] = item
    }
    for object in listing.objects where object.key != prefix {
      let directory = object.key.hasSuffix("/")
      let item = try item(
        key: object.key, size: object.size, date: object.modified, directory: directory)
      items["\(directory ? "dir" : "file"):\(item.path.value)"] = item
    }
    return items.values.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try ensureConnected()
    if path.value == "/" {
      return RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    let key = objectKey(path, directory: false)
    let object = try await headObject(key)
    if let object {
      return try item(
        key: key, size: object.size, date: object.modified, directory: false)
    }
    let children = try await listAll(prefix: key + "/", delimiter: nil).objects
    guard !children.isEmpty else { throw RemoteError.posix(ENOENT) }
    return try item(
      key: key, size: 0, date: children.map(\.modified).max() ?? .distantPast,
      directory: true)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try ensureConnected()
    let key = objectKey(path, directory: false)
    var headers: [String: String] = [:]
    if let range {
      guard range.lowerBound >= 0, range.lowerBound < range.upperBound else {
        throw RemoteError.posix(EINVAL)
      }
      headers["range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
    }
    let request = try signedRequest(method: "GET", path: key, headers: headers)
    let stream = try await transport.stream(request)
    try check(stream.response, allowing: range == nil ? [200] : [206])
    if let range,
      !Self.validContentRange(stream.response.header("Content-Range"), requested: range)
    {
      throw RemoteError.protocolError
    }
    return stream.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    let key = objectKey(path, directory: false)
    if size == 0 || size < multipartThreshold {
      let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
      try await putConditionally(key: key, body: data)
      progress?(size, size)
      return
    }
    try await multipartWrite(key: key, localFile: localFile, size: size)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try ensureConnected()
    guard path.value != "/" else { return }
    let key = objectKey(path, directory: true)
    try await putConditionally(key: key, body: Data())
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try ensureConnected()
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let key = objectKey(path, directory: false)
    let exact = try await headObject(key)
    let descendants = try await listAll(prefix: key + "/", delimiter: nil).objects
    guard exact != nil || !descendants.isEmpty else { throw RemoteError.posix(ENOENT) }
    if !recursive, descendants.contains(where: { $0.key != key + "/" }) {
      throw RemoteError.posix(ENOTEMPTY)
    }
    var keys = descendants.map(\.key)
    if exact != nil { keys.append(key) }
    try await deleteObjects(keys)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try ensureConnected()
    guard from.value != "/", to.value != "/", from != to else {
      throw RemoteError.posix(EINVAL)
    }
    let sourceKey = objectKey(from, directory: false)
    let targetKey = objectKey(to, directory: false)
    guard !targetKey.hasPrefix(sourceKey + "/") else { throw RemoteError.posix(EINVAL) }
    let sourceExact = try await headObject(sourceKey)
    let sourceChildren = try await listAll(prefix: sourceKey + "/", delimiter: nil).objects
    guard sourceExact != nil || !sourceChildren.isEmpty else {
      throw RemoteError.posix(ENOENT)
    }
    if try await pathExists(key: targetKey) { throw RemoteError.posix(EEXIST) }

    var copiedKeys: [String] = []
    do {
      if sourceExact != nil, sourceChildren.isEmpty {
        try await copy(sourceKey: sourceKey, destinationKey: targetKey)
        copiedKeys.append(targetKey)
      } else {
        if sourceExact != nil {
          try await copy(sourceKey: sourceKey, destinationKey: targetKey)
          copiedKeys.append(targetKey)
        }
        for object in sourceChildren {
          guard object.key.hasPrefix(sourceKey + "/") else {
            throw RemoteError.protocolError
          }
          let suffix = object.key.dropFirst(sourceKey.count)
          let destination = targetKey + String(suffix)
          try await copy(sourceKey: object.key, destinationKey: destination)
          copiedKeys.append(destination)
        }
      }
    } catch {
      let provider = self
      let cleanup = Task.detached {
        try? await provider.deleteObjects(copiedKeys)
      }
      await cleanup.value
      throw error
    }
    var keys = sourceChildren.map(\.key)
    if sourceExact != nil { keys.append(sourceKey) }
    try await deleteObjects(keys)
  }

  private func copy(sourceKey: String, destinationKey: String) async throws {
    for attempt in 0..<2 {
      let request = try signedRequest(
        method: "PUT", path: destinationKey,
        headers: [
          "x-amz-copy-source": Self.encodePath("/\(configuration.bucket)/\(sourceKey)"),
          "if-none-match": "*",
        ])
      let response = try await transport.send(request)
      if Self.isConditionalConflict(response) {
        if attempt == 0 { continue }
        throw RemoteError.posix(EEXIST)
      }
      try check(response, allowing: [200])
      return
    }
  }

  private func multipartWrite(key: String, localFile: URL, size: Int64) async throws {
    guard partSize >= 5 * 1_024 * 1_024, partSize <= 5 * 1_024 * 1_024 * 1_024 else {
      throw RemoteError.posix(EINVAL)
    }
    guard size > 0, (size - 1) / partSize + 1 <= 10_000 else {
      throw RemoteError.posix(EFBIG)
    }
    for attempt in 0..<2 {
      do {
        try await multipartAttempt(key: key, localFile: localFile, size: size)
        return
      } catch S3AttemptError.conditionalConflict {
        if attempt == 1 { throw RemoteError.posix(EEXIST) }
      }
    }
  }

  private func multipartAttempt(key: String, localFile: URL, size: Int64) async throws {
    try await ensureMissingObject(key)
    let initiated = try await transport.send(
      try signedRequest(
        method: "POST", path: key, query: [URLQueryItem(name: "uploads", value: "")]))
    try check(initiated, allowing: [200])
    guard
      let uploadID = S3MultipartParser.value(named: "UploadId", in: initiated.body),
      !uploadID.isEmpty
    else { throw RemoteError.protocolError }
    let handle = try FileHandle(forReadingFrom: localFile)
    defer { try? handle.close() }
    var etags: [(Int, String)] = []
    do {
      var offset: Int64 = 0
      var number = 1
      while offset < size {
        try Task.checkCancellation()
        let length = min(partSize, size - offset)
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
          throw RemoteError.posix(EIO)
        }
        let request = try signedRequest(
          method: "PUT", path: key, body: data,
          query: [
            URLQueryItem(name: "partNumber", value: String(number)),
            URLQueryItem(name: "uploadId", value: uploadID),
          ])
        let response = try await transport.send(request)
        try check(response, allowing: [200])
        guard let etag = response.header("ETag"), !etag.isEmpty else {
          throw RemoteError.protocolError
        }
        etags.append((number, etag))
        offset += length
        number += 1
        progress?(offset, size)
      }
      try await ensureMissingObject(key)
      let complete = try signedRequest(
        method: "POST", path: key, headers: ["if-none-match": "*"],
        body: S3MultipartParser.complete(etags: etags),
        query: [URLQueryItem(name: "uploadId", value: uploadID)])
      let response = try await transport.send(complete)
      if Self.isConditionalConflict(response) {
        throw S3AttemptError.conditionalConflict
      }
      try check(response, allowing: [200])
    } catch {
      let request = try signedRequest(
        method: "DELETE", path: key,
        query: [URLQueryItem(name: "uploadId", value: uploadID)])
      let transport = transport
      let cleanup = Task.detached {
        _ = try? await transport.send(request)
      }
      await cleanup.value
      throw error
    }
  }

  private func putConditionally(key: String, body: Data) async throws {
    for attempt in 0..<2 {
      try await ensureMissingObject(key)
      let request = try signedRequest(
        method: "PUT", path: key, headers: ["if-none-match": "*"], body: body)
      let response = try await transport.send(request)
      if Self.isConditionalConflict(response) {
        if attempt == 0 { continue }
        throw RemoteError.posix(EEXIST)
      }
      try check(response, allowing: [200, 201])
      return
    }
  }

  private func headObject(_ key: String) async throws -> S3ObjectInfo? {
    let request = try signedRequest(method: "HEAD", path: key)
    let response = try await transport.send(request)
    switch response.status {
    case 200:
      let size = Int64(response.header("Content-Length") ?? "0") ?? 0
      let modified =
        response.header("Last-Modified").flatMap(Self.parseHTTPDate) ?? .distantPast
      return S3ObjectInfo(key: key, size: size, modified: modified)
    case 404:
      return nil
    default:
      try check(response, allowing: [])
      return nil
    }
  }

  private func ensureMissingObject(_ key: String) async throws {
    if try await headObject(key) != nil { throw RemoteError.posix(EEXIST) }
  }

  private func pathExists(key: String) async throws -> Bool {
    if try await headObject(key) != nil { return true }
    return try await !listAll(prefix: key + "/", delimiter: nil).objects.isEmpty
  }

  private func listAll(prefix: String, delimiter: String?) async throws -> S3ListResult {
    var continuation: String?
    var objects: [S3ListObject] = []
    var prefixes: [String] = []
    while true {
      var query = [
        URLQueryItem(name: "list-type", value: "2"),
        URLQueryItem(name: "prefix", value: prefix),
        URLQueryItem(name: "max-keys", value: "1000"),
      ]
      if let delimiter { query.append(URLQueryItem(name: "delimiter", value: delimiter)) }
      if let continuation {
        query.append(URLQueryItem(name: "continuation-token", value: continuation))
      }
      let request = try signedRequest(method: "GET", path: "", query: query)
      let response = try await transport.send(request)
      try check(response, allowing: [200])
      let page = try S3ListParser.parse(response.body)
      objects.append(contentsOf: page.objects)
      prefixes.append(contentsOf: page.prefixes)
      guard page.isTruncated else { break }
      guard let next = page.nextToken, next != continuation else {
        throw RemoteError.protocolError
      }
      continuation = next
    }
    return S3ListResult(objects: objects, prefixes: prefixes)
  }

  private func deleteObjects(_ keys: [String]) async throws {
    var seen = Set<String>()
    for key in keys where seen.insert(key).inserted {
      let request = try signedRequest(method: "DELETE", path: key)
      try check(try await transport.send(request), allowing: [200, 204])
    }
  }

  func signedRequest(
    method: String, path: String, headers initial: [String: String] = [:], body: Data = Data(),
    query: [URLQueryItem] = [], now: Date = Date()
  ) throws -> URLRequest {
    let amzDate = Self.amzDate(now)
    let date = String(amzDate.prefix(8))
    let payloadHash = Self.sha256Hex(body)
    var headers = initial.mapKeys { $0.lowercased() }
    headers["host"] = requestHost
    headers["x-amz-content-sha256"] = payloadHash
    headers["x-amz-date"] = amzDate
    let canonicalHeaders = headers.keys.sorted().map {
      "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }.joined()
    let signedHeaders = headers.keys.sorted().joined(separator: ";")
    let encodedPath = Self.encodePath(canonicalPath(path))
    let encodedQuery = Self.canonicalQuery(query)
    let canonicalRequest = [
      method, encodedPath, encodedQuery, canonicalHeaders,
      signedHeaders, payloadHash,
    ].joined(separator: "\n")
    let scope = "\(date)/\(configuration.region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let dateKey = Self.hmac(key: Data(("AWS4" + configuration.secretKey).utf8), message: date)
    let regionKey = Self.hmac(key: dateKey, message: configuration.region)
    let serviceKey = Self.hmac(key: regionKey, message: "s3")
    let signingKey = Self.hmac(key: serviceKey, message: "aws4_request")
    let signature = Self.hmac(key: signingKey, message: stringToSign).hex
    headers["authorization"] =
      "AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
    if !configuration.pathStyle, let host = components.host {
      components.host = "\(configuration.bucket).\(host)"
    }
    components.percentEncodedPath = encodedPath
    components.percentEncodedQuery = query.isEmpty ? nil : encodedQuery
    guard let url = components.url else { throw RemoteError.protocolError }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = method
    request.httpBody = body.isEmpty ? nil : body
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  private var requestHost: String {
    guard let host = configuration.endpoint.host else { return "" }
    let hostname = configuration.pathStyle ? host : "\(configuration.bucket).\(host)"
    guard let port = configuration.endpoint.port else { return hostname }
    return "\(hostname):\(port)"
  }

  private func canonicalPath(_ key: String) -> String {
    if configuration.pathStyle {
      return "/\(configuration.bucket)" + (key.isEmpty ? "" : "/\(key)")
    }
    return "/" + key
  }

  private func objectKey(_ path: RemotePath, directory: Bool) -> String {
    let key = path.value.dropFirst()
    if directory, !key.isEmpty, !key.hasSuffix("/") { return key + "/" }
    return String(key)
  }

  private func item(key: String, size: Int64, date: Date, directory: Bool) throws -> RemoteItem {
    let normalizedKey = directory && key.hasSuffix("/") ? String(key.dropLast()) : key
    let name = String(normalizedKey.split(separator: "/").last ?? "")
    guard !name.isEmpty else { throw RemoteError.protocolError }
    return RemoteItem(
      path: try RemotePath("/" + key), name: name, isDirectory: directory, size: size,
      modified: date)
  }

  private func ensureConnected() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func check(_ response: HTTPResponse, allowing statuses: Set<Int>) throws {
    let error = S3ErrorParser.parse(response.body)
    if statuses.contains(response.status), error == nil { return }
    if let error {
      switch error.code {
      case "AccessDenied", "AccountProblem", "InvalidAccessKeyId", "SignatureDoesNotMatch":
        throw RemoteError.posix(EACCES)
      case "NoSuchBucket", "NoSuchKey", "NoSuchUpload":
        throw RemoteError.posix(ENOENT)
      case "PreconditionFailed":
        throw RemoteError.posix(EEXIST)
      case "ConditionalRequestConflict":
        throw RemoteError.posix(EAGAIN)
      case "SlowDown", "Throttling", "ThrottlingException", "RequestLimitExceeded":
        throw RemoteError.rateLimited
      case "EntityTooLarge":
        throw RemoteError.posix(EFBIG)
      case "EntityTooSmall", "InvalidPart", "InvalidPartOrder", "InvalidRequest":
        throw RemoteError.posix(EINVAL)
      case "InsufficientStorage", "QuotaExceeded":
        throw RemoteError.posix(ENOSPC)
      case "NotImplemented":
        throw RemoteError.posix(ENOTSUP)
      default:
        break
      }
      if (200..<300).contains(response.status) {
        throw RemoteError.posix(EIO)
      }
    }
    switch response.status {
    case 400: throw RemoteError.posix(EINVAL)
    case 401, 403: throw RemoteError.posix(EACCES)
    case 404: throw RemoteError.posix(ENOENT)
    case 409: throw RemoteError.posix(EEXIST)
    case 412: throw RemoteError.posix(EEXIST)
    case 416: throw RemoteError.posix(EINVAL)
    case 429, 503: throw RemoteError.rateLimited
    case 501, 505: throw RemoteError.posix(ENOTSUP)
    case 408, 504: throw RemoteError.posix(ETIMEDOUT)
    case 507: throw RemoteError.posix(ENOSPC)
    case 500...599: throw RemoteError.posix(EIO)
    default: throw RemoteError.protocolError
    }
  }

  private static func isConditionalConflict(_ response: HTTPResponse) -> Bool {
    if S3ErrorParser.parse(response.body)?.code == "ConditionalRequestConflict" {
      return true
    }
    return response.status == 409
  }

  static func validContentRange(_ header: String?, requested: Range<Int64>) -> Bool {
    guard let header, header.hasPrefix("bytes ") else { return false }
    let pieces = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, let total = Int64(pieces[1]),
      total > requested.upperBound - 1
    else { return false }
    let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }

  private static func amzDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func parseHTTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.date(from: value)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hmac(key: Data, message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
  }

  private static func canonicalQuery(_ items: [URLQueryItem]) -> String {
    var encoded: [(String, String)] = []
    for item in items {
      encoded.append((encodeQuery(item.name), encodeQuery(item.value ?? "")))
    }
    encoded.sort { left, right in
      if left.0 == right.0 { return left.1 < right.1 }
      return left.0 < right.0
    }
    return encoded.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
  }

  private static func encodeQuery(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~")))
      ?? ""
  }

  static func encodePath(_ value: String) -> String {
    value.split(separator: "/", omittingEmptySubsequences: false).map {
      encodeQuery(String($0))
    }.joined(separator: "/")
  }
}

private struct S3ObjectInfo {
  let key: String
  let size: Int64
  let modified: Date
}

private struct S3ListResult {
  let objects: [S3ListObject]
  let prefixes: [String]
}

private enum S3AttemptError: Error {
  case conditionalConflict
}

extension Data {
  fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Dictionary {
  fileprivate func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
    [T: Value](uniqueKeysWithValues: map { (transform($0.key), $0.value) })
  }
}
