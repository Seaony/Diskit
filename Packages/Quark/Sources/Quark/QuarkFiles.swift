import Core
import CryptoKit
import Foundation

struct QuarkFile: Decodable, Sendable {
  let fid: String
  let fileName: String
  let file: Bool
  let size: Int64
  let updatedAt: Int64
  // 同目录重名时 Finder 里显示的名字，列目录时分配
  var displayName: String?
  enum CodingKeys: String, CodingKey {
    case fid, file, size
    case fileName = "file_name"
    case updatedAt = "updated_at"
  }
  // 网盘上的真实名字
  var rawName: String { QuarkNames.decode(fileName) }
  var name: String { displayName ?? rawName }
  func item(at path: RemotePath) throws -> RemoteItem {
    guard !fid.isEmpty, !rawName.isEmpty, !rawName.contains("/"), rawName != ".", rawName != "..",
      size >= 0
    else { throw RemoteError.protocolError }
    return RemoteItem(
      path: path, name: name, isDirectory: !file, size: size,
      modified: Date(timeIntervalSince1970: Double(updatedAt) / 1000))
  }
}

struct QuarkStatus: Decodable {
  let status: Int
  let code: Int
}
struct QuarkMutation: Decodable {
  struct Result: Decodable {
    let taskID: String?
    enum CodingKeys: String, CodingKey { case taskID = "task_id" }
  }
  let data: Result?
}
struct QuarkTask: Decodable, Sendable {
  let status: Int
}
struct QuarkData<T: Decodable>: Decodable { let data: T }
extension QuarkData: Sendable where T: Sendable {}
struct QuarkFileList: Decodable {
  struct Contents: Decodable { let list: [QuarkFile] }
  struct Page: Decodable {
    let total: Int
    enum CodingKeys: String, CodingKey { case total = "_total" }
  }
  let data: Contents
  let metadata: Page
}
struct QuarkDownload: Decodable {
  let downloadURL: URL
  enum CodingKeys: String, CodingKey { case downloadURL = "download_url" }
}
struct QuarkPreUpload: Decodable {
  struct Callback: Codable {
    let callbackUrl: String
    let callbackBody: String
  }
  struct Upload: Decodable {
    let taskID: String
    let uploadID: String
    let objectKey: String
    let uploadURL: URL
    let fid: String
    let bucket: String
    let callback: Callback
    let authInfo: String
    enum CodingKeys: String, CodingKey {
      case taskID = "task_id"
      case uploadID = "upload_id"
      case objectKey = "obj_key"
      case uploadURL = "upload_url"
      case fid, bucket, callback
      case authInfo = "auth_info"
    }
  }
  struct Options: Decodable {
    let partSize: Int64
    enum CodingKeys: String, CodingKey { case partSize = "part_size" }
  }
  let data: Upload
  let metadata: Options
}
struct QuarkHashResult: Decodable { let finish: Bool }
struct QuarkUploadAuthorization: Decodable {
  let authKey: String
  enum CodingKeys: String, CodingKey { case authKey = "auth_key" }
}

struct QuarkDigests: Equatable, Sendable {
  let md5: String
  let sha1: String
  static func file(_ url: URL) throws -> QuarkDigests {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var md5 = Insecure.MD5()
    var sha1 = Insecure.SHA1()
    while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
      try Task.checkCancellation()
      md5.update(data: bytes)
      sha1.update(data: bytes)
    }
    return QuarkDigests(
      md5: md5.finalize().map { String(format: "%02x", $0) }.joined(),
      sha1: sha1.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

struct QuarkPart: Equatable, Sendable {
  let number: Int
  let offset: Int64
  let length: Int64
  static func split(size: Int64, partSize: Int64) throws -> [QuarkPart] {
    guard size >= 0, partSize > 0, partSize <= 5 * 1024 * 1024 * 1024 else {
      throw RemoteError.protocolError
    }
    if size == 0 { return [QuarkPart(number: 1, offset: 0, length: 0)] }
    var parts: [QuarkPart] = []
    var offset: Int64 = 0
    while offset < size {
      guard parts.count < 10_000 else { throw RemoteError.posix(EFBIG) }
      let length = min(partSize, size - offset)
      parts.append(QuarkPart(number: parts.count + 1, offset: offset, length: length))
      offset += length
    }
    return parts
  }
}

enum QuarkOSS {
  static let client = "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit"
  static func date(_ value: Date = Date()) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return format.string(from: value)
  }
  static func resource(_ upload: QuarkPreUpload.Upload, part: Int?) -> String {
    "/" + upload.bucket + "/" + upload.objectKey + "?" + (part.map { "partNumber=\($0)&" } ?? "")
      + "uploadId=" + upload.uploadID
  }
  static func url(_ upload: QuarkPreUpload.Upload, part: Int?) throws -> URL {
    guard let origin = upload.uploadURL.host, origin.hasSuffix(".aliyuncs.com"),
      !upload.bucket.isEmpty,
      upload.bucket.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
      }),
      !upload.objectKey.isEmpty, !upload.objectKey.hasPrefix("/"), !upload.uploadID.isEmpty
    else { throw RemoteError.protocolError }
    var parts = URLComponents()
    parts.scheme = "https"
    parts.host = upload.bucket + "." + origin
    parts.path = "/" + upload.objectKey
    parts.queryItems =
      (part.map { [URLQueryItem(name: "partNumber", value: String($0))] } ?? []) + [
        URLQueryItem(name: "uploadId", value: upload.uploadID)
      ]
    guard let url = parts.url else { throw RemoteError.protocolError }
    return url
  }
  static func canonical(
    method: String, contentMD5: String = "", contentType: String, date: String,
    headers: [String: String], resource: String
  ) -> String {
    let fields = headers.keys.sorted().map { $0.lowercased() + ":" + headers[$0]! }.joined(
      separator: "\n")
    return [method, contentMD5, contentType, date, fields, resource].joined(separator: "\n")
  }
  static func completeBody(_ etags: [String]) -> Data {
    func escaped(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }
    let parts = etags.enumerated().map {
      "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\(escaped($0.element))</ETag></Part>"
    }.joined()
    return Data(
      ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>" + parts
        + "</CompleteMultipartUpload>").utf8)
  }
  static func contentMD5(_ body: Data) -> String {
    Data(Insecure.MD5.hash(data: body)).base64EncodedString()
  }
  static func callback(_ callback: QuarkPreUpload.Callback) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(callback).base64EncodedString()
  }
}

enum QuarkNames {
  private static let expression = try! NSRegularExpression(
    pattern: "&(?:#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);")

  static func decode(_ text: String) -> String {
    var output = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .reversed()
    {
      guard let range = Range(match.range, in: output) else { continue }
      let entity = String(output[range].dropFirst().dropLast())
      let replacement: String?
      if entity.hasPrefix("#x"), let value = UInt32(entity.dropFirst(2), radix: 16),
        let scalar = UnicodeScalar(value)
      {
        replacement = String(scalar)
      } else if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()),
        let scalar = UnicodeScalar(value)
      {
        replacement = String(scalar)
      } else {
        replacement =
          ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}"][entity]
      }
      if let replacement { output.replaceSubrange(range, with: replacement) }
    }
    return output
  }
}
