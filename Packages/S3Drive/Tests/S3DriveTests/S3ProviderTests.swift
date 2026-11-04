import Core
import Foundation
import Synchronization
import Testing

@testable import S3Drive

private final class FakeTransport: HTTPTransport, Sendable {
  let responses: Mutex<[HTTPResponse]>
  let streams: Mutex<[HTTPStreamResponse]>
  let requests = Mutex<[URLRequest]>([])

  init(_ responses: [HTTPResponse] = [], streams: [HTTPStreamResponse] = []) {
    self.responses = Mutex(responses)
    self.streams = Mutex(streams)
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return responses.withLock {
      guard !$0.isEmpty else { return HTTPResponse(status: 500) }
      return $0.removeFirst()
    }
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.withLock { $0.append(request) }
    return streams.withLock {
      guard !$0.isEmpty else {
        return HTTPStreamResponse(
          response: HTTPResponse(status: 500), body: AsyncThrowingStream { $0.finish() })
      }
      return $0.removeFirst()
    }
  }
}

private func provider(
  _ transport: FakeTransport, threshold: Int64 = 64 * 1_024 * 1_024,
  partSize: Int64 = 16 * 1_024 * 1_024, pathStyle: Bool = true
) -> S3Provider {
  S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: "https://s3.example.com")!, region: "us-east-1", bucket: "photos",
      accessKey: "AKIDEXAMPLE", secretKey: "secret", pathStyle: pathStyle),
    transport: transport, multipartThreshold: threshold, partSize: partSize)
}

private func stream(_ status: Int, headers: [String: String] = [:]) -> HTTPStreamResponse {
  HTTPStreamResponse(
    response: HTTPResponse(status: status, headers: headers),
    body: AsyncThrowingStream {
      $0.yield(Data("range".utf8))
      $0.finish()
    })
}

private func listXML(
  _ contents: [(String, Int)], prefixes: [String] = [],
  next: String? = nil, truncated: Bool = false
) -> HTTPResponse {
  let objects = contents.map {
    "<Contents><Key>\($0.0)</Key><Size>\($0.1)</Size>"
      + "<LastModified>2026-01-01T00:00:00Z</LastModified></Contents>"
  }.joined()
  let folders = prefixes.map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
  let token = next.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
  let body =
    "<ListBucketResult>\(objects)\(folders)<IsTruncated>\(truncated)</IsTruncated>"
    + "\(token)</ListBucketResult>"
  return HTTPResponse(status: 200, body: Data(body.utf8))
}

private func makeFile(_ bytes: Int) throws -> (URL, URL) {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appending(path: "payload.bin")
  try Data(repeating: 0x5a, count: bytes).write(to: file)
  return (directory, file)
}

private func encodedPath(_ request: URLRequest) -> String? {
  guard let url = request.url else { return nil }
  return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
}

@Test func servicePresetsUseOfficialAddressing() throws {
  #expect(S3ServicePreset.allCases.count == 7)
  let aws = try S3ServicePreset.amazonS3.addressing()
  #expect(aws.endpoint.absoluteString == "https://s3.us-east-1.amazonaws.com")
  #expect(aws.region == "us-east-1")
  #expect(!aws.pathStyle)

  let r2 = try S3ServicePreset.cloudflareR2.addressing(accountID: "account-123")
  #expect(r2.endpoint.absoluteString == "https://account-123.r2.cloudflarestorage.com")
  #expect(r2.region == "auto")
  #expect(!r2.pathStyle)
  let r2Configuration = try S3ServicePreset.cloudflareR2.configuration(
    bucket: "photos", accessKey: "key", secretKey: "secret", accountID: "account-123")
  #expect(r2Configuration.endpoint == r2.endpoint)
  #expect(r2Configuration.pathStyle == r2.pathStyle)

  let oss = try S3ServicePreset.aliyunOSS.addressing()
  #expect(oss.endpoint.absoluteString == "https://s3.oss-cn-hangzhou.aliyuncs.com")
  #expect(!oss.pathStyle)

  let cos = try S3ServicePreset.tencentCOS.addressing()
  #expect(cos.endpoint.absoluteString == "https://cos.ap-guangzhou.myqcloud.com")
  #expect(!cos.pathStyle)

  let kodo = try S3ServicePreset.qiniuKodo.addressing()
  #expect(kodo.endpoint.absoluteString == "https://s3.cn-east-1.qiniucs.com")
  #expect(!kodo.pathStyle)

  let minio = try S3ServicePreset.minIO.addressing(
    customEndpoint: URL(string: "https://minio.local:9000")!)
  #expect(minio.region == "us-east-1")
  #expect(minio.pathStyle)

  let b2 = try S3ServicePreset.backblazeB2.addressing()
  #expect(b2.endpoint.absoluteString == "https://s3.us-west-004.backblazeb2.com")
  #expect(b2.pathStyle)

  #expect(throws: S3PresetError.missingAccountID) {
    try S3ServicePreset.cloudflareR2.addressing()
  }
  #expect(throws: S3PresetError.customEndpointRequired) {
    try S3ServicePreset.minIO.addressing()
  }
}

@Test func signedVirtualHostRequestPercentEncodesPathOnce() async throws {
  let transport = FakeTransport(streams: [stream(200)])
  let s3 = provider(transport, pathStyle: false)
  try await s3.connect()
  _ = try await s3.read(try RemotePath("/folder/中文 file%.bin"), range: nil)
  let request = try #require(transport.requests.withLock { $0.first })
  let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
  #expect(components.host == "photos.s3.example.com")
  #expect(components.percentEncodedPath == "/folder/%E4%B8%AD%E6%96%87%20file%25.bin")
  #expect(request.value(forHTTPHeaderField: "host") == "photos.s3.example.com")
  #expect(
    request.value(forHTTPHeaderField: "Authorization")?.contains(
      "Credential=AKIDEXAMPLE/") == true)

  let pathTransport = FakeTransport(streams: [stream(200)])
  let pathS3 = provider(pathTransport)
  try await pathS3.connect()
  _ = try await pathS3.read(try RemotePath("/folder/中文 file%.bin"), range: nil)
  let pathRequest = try #require(pathTransport.requests.withLock { $0.first })
  let pathComponents = try #require(
    URLComponents(url: pathRequest.url!, resolvingAgainstBaseURL: false))
  #expect(
    pathComponents.percentEncodedPath
      == "/photos/folder/%E4%B8%AD%E6%96%87%20file%25.bin")
}

@Test func listAggregatesCommonPrefixesAndObjectsAcrossPages() async throws {
  let transport = FakeTransport([
    listXML([("a.txt", 5)], prefixes: ["photos/"], next: "next/page", truncated: true),
    listXML([("b.txt", 3)], prefixes: ["photos/"], truncated: false),
  ])
  let s3 = provider(transport)
  try await s3.connect()
  let items = try await s3.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["a.txt", "b.txt", "photos"])
  #expect(items.first { $0.name == "photos" }?.isDirectory == true)
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 2)
  let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
  #expect(query?.first { $0.name == "continuation-token" }?.value == "next/page")
}

@Test func truncatedPageWithoutTokenFails() async throws {
  let transport = FakeTransport([
    listXML([("a.txt", 5)], truncated: true)
  ])
  let s3 = provider(transport)
  try await s3.connect()
  await #expect(throws: RemoteError.protocolError) {
    _ = try await s3.list(try RemotePath("/"))
  }
}

@Test func statInfersDirectoryWithoutTrailingSlash() async throws {
  let transport = FakeTransport([
    HTTPResponse(status: 404),
    listXML([("docs/report.txt", 12)]),
  ])
  let s3 = provider(transport)
  try await s3.connect()
  let item = try await s3.stat(try RemotePath("/docs"))
  #expect(item.name == "docs")
  #expect(item.isDirectory)
  #expect(item.path == (try RemotePath("/docs")))
}

@Test func recursiveRemoveDeletesEveryNestedObject() async throws {
  let transport = FakeTransport([
    HTTPResponse(status: 404),
    listXML(
      [("tree/a.txt", 1), ("tree/sub/", 0)], next: "page-2", truncated: true),
    listXML([("tree/sub/b.txt", 2)], truncated: false),
    HTTPResponse(status: 204),
    HTTPResponse(status: 204),
    HTTPResponse(status: 204),
  ])
  let s3 = provider(transport)
  try await s3.connect()
  try await s3.remove(try RemotePath("/tree"), recursive: true)
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 6)
  let listing = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
  #expect(listing?.first { $0.name == "prefix" }?.value == "tree/")
  #expect(listing?.first { $0.name == "delimiter" } == nil)
  let deleted = requests.filter { $0.httpMethod == "DELETE" }.compactMap(encodedPath)
  #expect(
    deleted == [
      "/photos/tree/a.txt", "/photos/tree/sub/", "/photos/tree/sub/b.txt",
    ])
}

@Test func nonRecursiveDirectoryRemoveRejectsNonEmptyPrefix() async throws {
  let transport = FakeTransport([
    HTTPResponse(status: 404),
    listXML([("tree/file.txt", 1)]),
  ])
  let s3 = provider(transport)
  try await s3.connect()
  await #expect(throws: RemoteError.posix(ENOTEMPTY)) {
    try await s3.remove(try RemotePath("/tree"), recursive: false)
  }
  #expect(!transport.requests.withLock { $0 }.contains { $0.httpMethod == "DELETE" })
}

@Test func recursiveMoveCopiesEveryNestedObjectThenDeletesSource() async throws {
  let transport = FakeTransport([
    HTTPResponse(status: 404),
    listXML(
      [("src/a.txt", 1), ("src/sub/", 0)], next: "page-2", truncated: true),
    listXML([("src/sub/b.txt", 2)], truncated: false),
    HTTPResponse(status: 404),
    listXML([]),
    HTTPResponse(status: 200),
    HTTPResponse(status: 200),
    HTTPResponse(status: 200),
    HTTPResponse(status: 204),
    HTTPResponse(status: 204),
    HTTPResponse(status: 204),
  ])
  let s3 = provider(transport)
  try await s3.connect()
  try await s3.move(try RemotePath("/src"), to: try RemotePath("/dst"))
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 11)
  let copies = requests.filter {
    $0.httpMethod == "PUT" && $0.value(forHTTPHeaderField: "x-amz-copy-source") != nil
  }
  #expect(
    copies.compactMap(encodedPath) == [
      "/photos/dst/a.txt", "/photos/dst/sub/", "/photos/dst/sub/b.txt",
    ])
  #expect(copies.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == "*" })
  let deleted = requests.filter { $0.httpMethod == "DELETE" }.compactMap(encodedPath)
  #expect(
    deleted == ["/photos/src/a.txt", "/photos/src/sub/", "/photos/src/sub/b.txt"])
}

@Test func rangeRequiresMatchingContentRange() async throws {
  let valid = FakeTransport(streams: [
    stream(206, headers: ["Content-Range": "bytes 10-19/100"])
  ])
  let s3 = provider(valid)
  try await s3.connect()
  _ = try await s3.read(try RemotePath("/movie.bin"), range: 10..<20)
  let request = try #require(valid.requests.withLock { $0.first })
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")

  let invalid = FakeTransport(streams: [
    stream(206, headers: ["Content-Range": "bytes 9-18/100"])
  ])
  let invalidProvider = provider(invalid)
  try await invalidProvider.connect()
  await #expect(throws: RemoteError.protocolError) {
    _ = try await invalidProvider.read(try RemotePath("/movie.bin"), range: 10..<20)
  }

  await #expect(throws: RemoteError.posix(EINVAL)) {
    _ = try await invalidProvider.read(try RemotePath("/movie.bin"), range: 10..<10)
  }
}

@Test func multipartThresholdAndLastPartBoundaries() async throws {
  let partSize = 5 * 1_024 * 1_024
  let (emptyDirectory, emptyFile) = try makeFile(0)
  defer { try? FileManager.default.removeItem(at: emptyDirectory) }
  let emptyTransport = FakeTransport([HTTPResponse(status: 200)])
  let empty = provider(emptyTransport, threshold: 0, partSize: Int64(partSize))
  try await empty.connect()
  try await empty.write(try RemotePath("/empty.bin"), from: emptyFile)
  #expect(emptyTransport.requests.withLock { $0 }.count == 1)

  let (directDirectory, directFile) = try makeFile(partSize - 1)
  defer { try? FileManager.default.removeItem(at: directDirectory) }
  let directTransport = FakeTransport([HTTPResponse(status: 200)])
  let direct = provider(
    directTransport, threshold: Int64(partSize), partSize: Int64(partSize))
  try await direct.connect()
  try await direct.write(try RemotePath("/direct.bin"), from: directFile)
  #expect(directTransport.requests.withLock { $0 }.count == 1)

  let (multipartDirectory, multipartFile) = try makeFile(partSize * 2 + 1)
  defer { try? FileManager.default.removeItem(at: multipartDirectory) }
  let multipartTransport = FakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(status: 200, headers: ["ETag": "\"one\""]),
    HTTPResponse(status: 200, headers: ["ETag": "\"two\""]),
    HTTPResponse(status: 200, headers: ["ETag": "\"three\""]),
    HTTPResponse(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8)),
  ])
  let multipart = provider(
    multipartTransport, threshold: Int64(partSize), partSize: Int64(partSize))
  try await multipart.connect()
  try await multipart.write(try RemotePath("/large.bin"), from: multipartFile)
  let requests = multipartTransport.requests.withLock { $0 }
  #expect(requests.count == 5)
  #expect(requests[1].httpBody?.count == partSize)
  #expect(requests[2].httpBody?.count == partSize)
  #expect(requests[3].httpBody?.count == 1)
  #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
  #expect(requests[4].value(forHTTPHeaderField: "If-None-Match") == "*")
}

@Test func multipartConditionalConflictReuploadsOnce() async throws {
  let partSize = 5 * 1_024 * 1_024
  let (directory, file) = try makeFile(partSize)
  defer { try? FileManager.default.removeItem(at: directory) }
  let conflict = Data(
    "<Error><Code>ConditionalRequestConflict</Code><Message>conflict</Message></Error>".utf8)
  let transport = FakeTransport([
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(status: 200, headers: ["ETag": "\"one\""]),
    HTTPResponse(status: 200, body: conflict),
    HTTPResponse(status: 204),
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>upload-2</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(status: 200, headers: ["ETag": "\"two\""]),
    HTTPResponse(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8)),
  ])
  let s3 = provider(transport, threshold: Int64(partSize), partSize: Int64(partSize))
  try await s3.connect()
  try await s3.write(try RemotePath("/race.bin"), from: file)
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 7)
  let completions = requests.filter {
    $0.httpMethod == "POST"
      && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .contains { $0.name == "uploadId" } == true
  }
  #expect(completions.count == 2)
  #expect(
    completions.allSatisfy {
      $0.value(forHTTPHeaderField: "If-None-Match") == "*"
    })
  #expect(
    (requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
      && (requests[4].value(forHTTPHeaderField: "If-None-Match") == nil))
}

@Test func xmlAndHTTPErrorsMapToRemoteErrors() async throws {
  func mappedError(_ response: HTTPResponse) async throws -> RemoteError? {
    let transport = FakeTransport([response])
    let s3 = provider(transport)
    try await s3.connect()
    do {
      _ = try await s3.spaceInfo()
      return nil
    } catch let error as RemoteError {
      return error
    }
  }

  #expect(
    try await mappedError(
      HTTPResponse(
        status: 403,
        body: Data("<Error><Code>AccessDenied</Code></Error>".utf8))) == .posix(EACCES))
  #expect(
    try await mappedError(
      HTTPResponse(
        status: 404, body: Data("<Error><Code>NoSuchKey</Code></Error>".utf8))) == .posix(ENOENT))
  #expect(
    try await mappedError(
      HTTPResponse(
        status: 409,
        body: Data("<Error><Code>ConditionalRequestConflict</Code></Error>".utf8)))
      == .posix(EAGAIN))
  #expect(
    try await mappedError(
      HTTPResponse(
        status: 503, body: Data("<Error><Code>SlowDown</Code></Error>".utf8)))
      == .rateLimited)
  #expect(try await mappedError(HTTPResponse(status: 429)) == .rateLimited)
  #expect(try await mappedError(HTTPResponse(status: 504)) == .posix(ETIMEDOUT))
  #expect(try await mappedError(HTTPResponse(status: 507)) == .posix(ENOSPC))
  #expect(try await mappedError(HTTPResponse(status: 500)) == .posix(EIO))
}

@Test(arguments: [true, false])
func paginationUsesCanonicalEncodedQueryOnTheWire(pathStyle: Bool) async throws {
  let token = "next+/= 中文%?"
  let transport = FakeTransport([
    listXML([("a.txt", 5)], next: token, truncated: true),
    listXML([("b.txt", 3)]),
  ])
  let s3 = provider(transport, pathStyle: pathStyle)
  try await s3.connect()
  let items = try await s3.list(try RemotePath("/"))
  #expect(items.map(\.name) == ["a.txt", "b.txt"])
  let requests = transport.requests.withLock { $0 }
  #expect(requests.count == 2)
  let first = try #require(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false))
  let second = try #require(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false))
  #expect(first.percentEncodedQuery == "delimiter=%2F&list-type=2&max-keys=1000&prefix=")
  #expect(
    second.percentEncodedQuery
      == "continuation-token=next%2B%2F%3D%20%E4%B8%AD%E6%96%87%25%3F&delimiter=%2F&list-type=2&max-keys=1000&prefix="
  )
  #expect(second.queryItems?.first { $0.name == "continuation-token" }?.value == token)
}

@Test(arguments: [0, 1, 2, 3])
func sigV4MatchesAllOfficialSingleChunkExamples(example: Int) async throws {
  // AWS 文档的公开示例值，不是真实凭据。
  let transport = FakeTransport()
  let s3 = S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1",
      bucket: "examplebucket", accessKey: "AKIAIOSFODNN7EXAMPLE",
      secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", pathStyle: false),
    transport: transport)
  let date = try #require(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
  let cases: [(String, String, [String: String], Data, [URLQueryItem], String, String)] = [
    (
      "GET", "test.txt", ["range": "bytes=0-9"], Data(), [],
      "host;range;x-amz-content-sha256;x-amz-date",
      "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    ),
    (
      "PUT", "test$file.text",
      ["date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
      Data("Welcome to Amazon S3.".utf8), [],
      "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class",
      "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    ),
    (
      "GET", "", [:], Data(), [URLQueryItem(name: "lifecycle", value: "")],
      "host;x-amz-content-sha256;x-amz-date",
      "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
    ),
    (
      "GET", "", [:], Data(),
      [URLQueryItem(name: "prefix", value: "J"), URLQueryItem(name: "max-keys", value: "2")],
      "host;x-amz-content-sha256;x-amz-date",
      "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
    ),
  ]
  let (method, path, headers, body, query, signedHeaders, signature) = cases[example]
  let request = try await s3.signedRequest(
    method: method, path: path, headers: headers, body: body, query: query, now: date)
  #expect(
    request.value(forHTTPHeaderField: "Authorization")
      == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=\(signedHeaders), Signature=\(signature)"
  )
  let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
  #expect(components.percentEncodedPath == ["/test.txt", "/test%24file.text", "/", "/"][example])
  #expect(
    components.percentEncodedQuery == [nil, nil, "lifecycle=", "max-keys=2&prefix=J"][example])
  #expect(transport.requests.withLock { $0.isEmpty })
}
