import Core
import CryptoKit
import Foundation

struct FlexibleInt64: Decodable, Equatable, Sendable {
  let value: Int64

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int64.self) {
      self.value = value
    } else if let text = try? container.decode(String.self), let value = Int64(text) {
      self.value = value
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "expected an integer or numeric string")
    }
  }
}

struct FlexibleString: Decodable, Equatable, Sendable {
  let value: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self.value = value
    } else if let value = try? container.decode(Int64.self) {
      self.value = String(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "expected a string or integer")
    }
  }
}

enum ChinaWebSupport {
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

  static func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func jsonRequest(
    _ url: URL, method: String = "POST", json: Any? = nil
  ) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let json {
      request.httpBody = try jsonData(json)
    }
    return request
  }

  static func checkHTTP(_ response: HTTPResponse) throws {
    guard (200..<300).contains(response.status) else {
      throw RemoteError.http(response.status)
    }
  }

  static func mapBusiness(code: Int?, message: String?) -> RemoteError {
    let text = message?.lowercased() ?? ""
    if text.contains("space") || text.contains("quota") || text.contains("空间")
      || text.contains("容量")
    {
      return .posix(ENOSPC)
    }
    if text.contains("already exist") || text.contains("same name")
      || text.contains("同名") || text.contains("已存在")
    {
      return .posix(EEXIST)
    }
    if text.contains("too large") || text.contains("file size") || text.contains("文件过大") {
      return .posix(EFBIG)
    }
    switch code {
    case 401, 403, 9008, 9100, 16: return .unauthorized
    case 404: return .posix(ENOENT)
    case 409, 412: return .posix(EEXIST)
    case 429, 503: return .rateLimited
    case 507, 9424, 4_000_012, 1_809_010_017, 1_909_011_527: return .posix(ENOSPC)
    default: return .posix(EIO)
    }
  }

  static func isValidRemoteName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
      && !value.utf8.contains(0)
  }

  static func parent(of path: RemotePath) -> RemotePath {
    let components = path.value.split(separator: "/").dropLast()
    return try! RemotePath(components.isEmpty ? "/" : "/" + components.joined(separator: "/"))
  }

  static func basename(_ path: RemotePath) -> String {
    path.value.split(separator: "/").last.map(String.init) ?? ""
  }

  static func parseDate(_ value: String?) -> Date {
    guard let value, !value.isEmpty else { return Date(timeIntervalSince1970: 0) }
    if let seconds = Int64(value) {
      return Date(timeIntervalSince1970: Double(seconds) / (value.count > 10 ? 1_000 : 1))
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }
    for format in ["yyyyMMddHHmmss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return Date(timeIntervalSince1970: 0)
  }

  static func validRange(
    _ header: String?, requested: Range<Int64>, size: Int64
  ) -> Bool {
    guard let header, header.lowercased().hasPrefix("bytes ") else { return false }
    let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard fields.count == 2, Int64(fields[1]) == size else { return false }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }

  static func trustedHost(_ host: String, domain: String) -> Bool {
    let value = host.lowercased()
    return value == domain || value.hasSuffix("." + domain)
  }

  static func percentEncodeJavaScript(_ value: String) -> String {
    let allowed: Set<UInt8> = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()".utf8)
    return value.utf8.map { byte in
      if allowed.contains(byte) { return String(UnicodeScalar(byte)) }
      return String(format: "%%%02X", byte)
    }.joined()
  }

  static func md5Hex(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func fileDigest(_ url: URL, algorithm: String) throws -> String {
    let normalized = algorithm.lowercased()
    guard ["md5", "sha1", "sha256"].contains(normalized) else {
      throw RemoteError.unsupported
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var md5 = Insecure.MD5()
    var sha1 = Insecure.SHA1()
    var sha256 = SHA256()
    while let block = try handle.read(upToCount: 65_536), !block.isEmpty {
      try Task.checkCancellation()
      switch normalized {
      case "md5": md5.update(data: block)
      case "sha1": sha1.update(data: block)
      default: sha256.update(data: block)
      }
    }
    let digest: [UInt8]
    switch normalized {
    case "md5": digest = Array(md5.finalize())
    case "sha1": digest = Array(sha1.finalize())
    default: digest = Array(sha256.finalize())
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func randomNonce() -> String {
    let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<16).map { _ in characters.randomElement()! })
  }

  static func dateTimestamp(now: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: now)
  }

  static func encodedPathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }
}
