import Core
import CryptoKit
import Foundation

struct PikPakPart: Equatable, Sendable {
  let number: Int
  let offset: Int64
  let length: Int64

  static func split(size: Int64, requestedPartSize: Int64) throws -> [PikPakPart] {
    guard size >= 0, requestedPartSize >= 100 * 1024, requestedPartSize <= 5 * 1024 * 1024 * 1024
    else { throw RemoteError.posix(EINVAL) }
    if size == 0 { return [] }
    let needed = size / 10_000 + (size % 10_000 == 0 ? 0 : 1)
    let partSize = max(requestedPartSize, needed)
    guard partSize <= 5 * 1024 * 1024 * 1024 else { throw RemoteError.posix(EFBIG) }
    var parts: [PikPakPart] = []
    var offset: Int64 = 0
    while offset < size {
      let length = min(partSize, size - offset)
      parts.append(PikPakPart(number: parts.count + 1, offset: offset, length: length))
      offset += length
    }
    return parts
  }
}

enum PikPakDigest {
  static func gcid(_ url: URL, size: Int64) throws -> String {
    guard size >= 0 else { throw RemoteError.posix(EINVAL) }
    if size == 0 {
      return Insecure.SHA1.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        .uppercased()
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var blockSize: Int64 = 256 * 1024
    while size / max(blockSize, 1) > 512, blockSize < 2 * 1024 * 1024 {
      blockSize *= 2
    }
    var outer = Insecure.SHA1()
    var remaining = size
    repeat {
      try Task.checkCancellation()
      let length = min(blockSize, remaining)
      var data = Data()
      while data.count < Int(length) {
        guard let chunk = try handle.read(upToCount: Int(length) - data.count), !chunk.isEmpty
        else { throw RemoteError.posix(EIO) }
        data.append(chunk)
      }
      outer.update(data: Data(Insecure.SHA1.hash(data: data)))
      remaining -= length
    } while remaining > 0
    return outer.finalize().map { String(format: "%02x", $0) }.joined().uppercased()
  }
}

struct PikPakS3Uploader: Sendable {
  private struct CreateResult {
    let uploadID: String
  }

  let session: PikPakSession
  let partSize: Int64

  func upload(
    from url: URL, size: Int64, parameters: PikPakResumable.Parameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    let parts = try PikPakPart.split(size: size, requestedPartSize: partSize)
    guard !parts.isEmpty else {
      progress?(0, 0)
      return
    }
    let created = try await create(parameters: parameters)
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var completed: [(Int, String)] = []
      for part in parts {
        try Task.checkCancellation()
        try handle.seek(toOffset: UInt64(part.offset))
        var body = Data()
        while body.count < Int(part.length) {
          guard let chunk = try handle.read(upToCount: Int(part.length) - body.count),
            !chunk.isEmpty
          else { throw RemoteError.posix(EIO) }
          body.append(chunk)
        }
        let response = try await request(
          method: "PUT", parameters: parameters,
          query: [
            URLQueryItem(name: "partNumber", value: String(part.number)),
            URLQueryItem(name: "uploadId", value: created.uploadID),
          ], body: body)
        try PikPakHTTP.check(response)
        guard let etag = response.header("ETag"), !etag.isEmpty else {
          throw PikPakError.invalidResponse
        }
        completed.append((part.number, etag))
        progress?(part.offset + part.length, size)
      }
      let response = try await request(
        method: "POST", parameters: parameters,
        query: [
          URLQueryItem(name: "uploadId", value: created.uploadID)
        ], body: completeBody(completed), contentType: "application/xml")
      try PikPakHTTP.check(response)
    } catch {
      let uploader = self
      let uploadID = created.uploadID
      let cleanup = Task.detached {
        _ = try? await uploader.request(
          method: "DELETE", parameters: parameters,
          query: [URLQueryItem(name: "uploadId", value: uploadID)], body: Data())
      }
      await cleanup.value
      throw error
    }
  }

  private func create(parameters: PikPakResumable.Parameters) async throws -> CreateResult {
    let response = try await request(
      method: "POST", parameters: parameters,
      query: [URLQueryItem(name: "uploads", value: "")], body: Data())
    try PikPakHTTP.check(response)
    guard let text = String(data: response.body, encoding: .utf8),
      let start = text.range(of: "<UploadId>"),
      let end = text.range(of: "</UploadId>", range: start.upperBound..<text.endIndex)
    else { throw PikPakError.invalidResponse }
    let id = String(text[start.upperBound..<end.lowerBound])
    guard !id.isEmpty else { throw PikPakError.invalidResponse }
    return CreateResult(uploadID: id)
  }

  private func request(
    method: String, parameters: PikPakResumable.Parameters, query: [URLQueryItem], body: Data,
    contentType: String? = nil
  ) async throws -> HTTPResponse {
    let endpoint = URL(string: "https://mypikpak.com/")!
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = Self.encodePath(
      "/" + parameters.bucket + "/" + parameters.key)
    components.percentEncodedQuery = Self.canonicalQuery(query)
    guard let url = components.url else { throw PikPakError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = method
    request.httpBody = body.isEmpty ? nil : body
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    let date = Self.amzDate(Date())
    let dateStamp = String(date.prefix(8))
    let payloadHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    var headers = [
      "host": url.host!,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": date,
      "x-amz-security-token": parameters.securityToken,
    ]
    if let contentType { headers["content-type"] = contentType }
    let sortedHeaders = headers.keys.sorted()
    let canonicalHeaders = sortedHeaders.map {
      "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }.joined()
    let signedHeaders = sortedHeaders.joined(separator: ";")
    let canonicalRequest = [
      method, components.percentEncodedPath, components.percentEncodedQuery ?? "",
      canonicalHeaders, signedHeaders, payloadHash,
    ].joined(separator: "\n")
    let scope = dateStamp + "/pikpak/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256", date, scope,
      SHA256.hash(data: Data(canonicalRequest.utf8)).map {
        String(format: "%02x", $0)
      }.joined(),
    ].joined(separator: "\n")
    let dateKey = Self.hmac(key: Data(("AWS4" + parameters.accessKeySecret).utf8), value: dateStamp)
    let regionKey = Self.hmac(key: dateKey, value: "pikpak")
    let serviceKey = Self.hmac(key: regionKey, value: "s3")
    let signingKey = Self.hmac(key: serviceKey, value: "aws4_request")
    let signature = Self.hmac(key: signingKey, value: stringToSign).map {
      String(format: "%02x", $0)
    }.joined()
    headers["authorization"] =
      "AWS4-HMAC-SHA256 Credential=\(parameters.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return try await session.sendSigned(request)
  }

  private func completeBody(_ parts: [(Int, String)]) -> Data {
    let body = parts.map {
      "<Part><PartNumber>\($0.0)</PartNumber><ETag>\(Self.xmlEscape($0.1))</ETag></Part>"
    }.joined()
    return Data(
      ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>" + body
        + "</CompleteMultipartUpload>").utf8)
  }

  private static func encodePath(_ value: String) -> String {
    value.split(separator: "/", omittingEmptySubsequences: false).map {
      encode(String($0))
    }.joined(separator: "/")
  }

  private static func canonicalQuery(_ items: [URLQueryItem]) -> String {
    var encoded: [(String, String)] = []
    for item in items {
      encoded.append((encode(item.name), encode(item.value ?? "")))
    }
    encoded.sort { left, right in
      if left.0 == right.0 { return left.1 < right.1 }
      return left.0 < right.0
    }
    return encoded.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
  }

  private static func encode(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
  }

  private static func amzDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func hmac(key: Data, value: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
  }

  private static func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
