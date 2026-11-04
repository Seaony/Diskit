import Core
import CryptoKit
import Foundation

struct MultipartFormData {
  let boundary = "kayoi-\(UUID().uuidString)"
  private(set) var body = Data()
  private(set) var containsFile = false

  mutating func addText(_ name: String, _ value: String) {
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n")
    body.append(Data(value.utf8))
    append("\r\n")
  }

  mutating func addFile(
    _ name: String, filename: String, mimeType: String = "application/octet-stream",
    data: Data
  ) {
    containsFile = true
    append("--\(boundary)\r\n")
    append(
      "Content-Disposition: form-data; name=\"\(escaped(name))\"; filename=\"\(escaped(filename))\"\r\n"
    )
    append("Content-Type: \(mimeType)\r\n\r\n")
    body.append(data)
    append("\r\n")
  }

  func finished() -> Data {
    var result = body
    result.append(Data("--\(boundary)--\r\n".utf8))
    return result
  }

  var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  private mutating func append(_ value: String) {
    body.append(Data(value.utf8))
  }

  private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "%22")
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
  }
}

struct CloudJSONEnvelope<Value: Decodable>: Decodable {
  let code: Int?
  let message: String?
  let data: Value?
  let errno: Int?
  let errmsg: String?

  enum CodingKeys: String, CodingKey {
    case code, message, data, errno, errmsg
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    code = try values.decodeIfPresent(Int.self, forKey: .code)
    message = try values.decodeIfPresent(String.self, forKey: .message)
    data = try values.decodeIfPresent(Value.self, forKey: .data)
    errno = try values.decodeIfPresent(Int.self, forKey: .errno)
    errmsg = try values.decodeIfPresent(String.self, forKey: .errmsg)
  }
}

enum CloudDriveSupport {
  static func jsonRequest(
    _ url: URL, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]
  ) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let json {
      request.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    return request
  }

  static func formRequest(
    _ url: URL, method: String = "POST", fields: [String: String],
    headers: [String: String] = [:]
  ) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = method
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = encodedForm(fields).data(using: .utf8)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  static func multipartRequest(
    _ url: URL, method: String = "POST", form: MultipartFormData,
    headers: [String: String] = [:]
  ) -> URLRequest {
    var request = URLRequest(
      url: url,
      timeoutInterval: form.containsFile ? RemoteTimeout.transferIdle : RemoteTimeout.cloudRequest)
    request.httpMethod = method
    request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = form.finished()
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  static func url(_ value: String, query: [URLQueryItem] = []) throws -> URL {
    guard var components = URLComponents(string: value) else {
      throw RemoteError.protocolError
    }
    if !query.isEmpty {
      components.queryItems = (components.queryItems ?? []) + query
    }
    guard let url = components.url else { throw RemoteError.protocolError }
    return url
  }

  static func encodedForm(_ fields: [String: String]) -> String {
    fields.map {
      encode($0.key) + "=" + encode($0.value)
    }.sorted().joined(separator: "&")
  }

  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
  }

  static func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sha1Hex(_ data: Data, uppercase: Bool = false) -> String {
    let value = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return uppercase ? value.uppercased() : value
  }

  static func mapHTTP(_ status: Int) -> RemoteError? {
    switch status {
    case 200..<300: nil
    case 401: .unauthorized
    case 403: .posix(EACCES)
    case 404: .posix(ENOENT)
    case 409, 412: .posix(EIO)
    case 416: .posix(EINVAL)
    case 429, 503: .rateLimited
    case 507: .posix(ENOSPC)
    default: .http(status)
    }
  }

  static func mapHTTP(_ response: HTTPResponse) -> RemoteError? {
    let text = String(decoding: response.body, as: UTF8.self).lowercased()
    if isRateLimited(response, text: text) {
      return .rateLimited
    }
    if isStorageFull(response, text: text) {
      return .posix(ENOSPC)
    }
    guard let fallback = mapHTTP(response.status) else { return nil }
    if isPermissionDenied(text) {
      return .posix(EACCES)
    }
    if isNameConflict(response, text: text) {
      return .posix(EEXIST)
    }
    return fallback
  }

  static func sendWithRetry(
    _ transport: any HTTPTransport, _ request: URLRequest, attempts: Int = 3
  ) async throws -> HTTPResponse {
    for attempt in 0..<max(1, attempts) {
      let response = try await transport.send(request)
      guard shouldRetry(response), attempt + 1 < attempts else { return response }
      try await Task.sleep(for: .seconds(retryDelay(response, attempt: attempt)))
    }
    throw RemoteError.rateLimited
  }

  static func streamWithRetry(
    _ transport: any HTTPTransport, _ request: URLRequest, attempts: Int = 3
  ) async throws -> HTTPStreamResponse {
    for attempt in 0..<max(1, attempts) {
      let response = try await transport.stream(request)
      guard shouldRetry(response.response), attempt + 1 < attempts else { return response }
      try await Task.sleep(
        for: .seconds(retryDelay(response.response, attempt: attempt)))
    }
    throw RemoteError.rateLimited
  }

  static func emptyStream() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  static func isExplicitlyMissing(_ error: Error) -> Bool {
    guard let error = error as? RemoteError else { return false }
    switch error {
    case .posix(ENOENT), .http(404): return true
    default: return false
    }
  }

  private static func shouldRetry(_ response: HTTPResponse) -> Bool {
    if response.status == 429 || response.status == 503 || response.status == 504 {
      return true
    }
    let text = String(decoding: response.body, as: UTF8.self).lowercased()
    return isRateLimited(response, text: text)
  }

  private static func isRateLimited(_ response: HTTPResponse, text: String) -> Bool {
    let markers = [
      "ratelimitexceeded", "userratelimitexceeded", "too_many_write_operations",
      "activitylimitreached", "requestratelimited", "refresh frequently",
    ]
    let codes = responseIntegerValues(response)
    return markers.contains { text.contains($0) }
      || [429, 5_113, 40_140_117].contains(codes.code ?? -1)
      || codes.errno == 42_905
  }

  private static func isStorageFull(_ response: HTTPResponse, text: String) -> Bool {
    let markers = [
      "insufficient_space", "storagequotaexceeded", "quotalimitreached", "maxquotareached",
      "not enough space",
    ]
    let codes = responseIntegerValues(response)
    return markers.contains { text.contains($0) }
      || codes.code == 507
      || codes.errno == -10
  }

  private static func isPermissionDenied(_ text: String) -> Bool {
    let markers = [
      "insufficientfilepermissions", "no_write_permission", "accessdenied", "permission_denied",
    ]
    return markers.contains { text.contains($0) }
  }

  private static func isNameConflict(_ response: HTTPResponse, text: String) -> Bool {
    let markers = [
      "namealreadyexists", "name already exists", "filealreadyexists",
      "file already exists", "alreadyexists", "already exists", "path/conflict",
      "requested identifier already exists",
    ]
    let codes = responseIntegerValues(response)
    return markers.contains { text.contains($0) }
      || [5_060, 990_001, 10, 31_061].contains(codes.code ?? -1)
      || codes.errno == -8
  }

  private static func responseIntegerValues(_ response: HTTPResponse) -> (code: Int?, errno: Int?) {
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { return (nil, nil) }
    return (integerValue(object["code"]), integerValue(object["errno"]))
  }

  private static func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static func retryDelay(_ response: HTTPResponse, attempt: Int) -> Int64 {
    if let value = response.header("Retry-After"),
      let seconds = Int64(value.trimmingCharacters(in: .whitespaces))
    {
      return min(max(seconds, 0), 60)
    }
    if let value = response.header("Retry-After") {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
      if let date = formatter.date(from: value) {
        return min(max(Int64(date.timeIntervalSinceNow.rounded(.up)), 0), 60)
      }
    }
    return min(Int64(1 << min(attempt, 5)), 30)
  }

  static func parseDate(_ value: String?) -> Date {
    guard let value else { return Date(timeIntervalSince1970: 0) }
    if let date = RemoteTimestamp.parse(
      value, assumedTimeZone: TimeZone(secondsFromGMT: 8 * 3_600)!)
    {
      return date
    }
    for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return Date(timeIntervalSince1970: 0)
  }

  static func parent(_ path: RemotePath) -> RemotePath {
    let parts = path.value.split(separator: "/").dropLast()
    return try! RemotePath(parts.isEmpty ? "/" : "/" + parts.joined(separator: "/"))
  }

  static func basename(_ path: RemotePath) -> String {
    String(path.value.split(separator: "/").last ?? "")
  }
}
