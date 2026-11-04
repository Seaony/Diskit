import Core
import Foundation
import Testing

@testable import S3Drive

private actor AuditTransport: HTTPTransport {
  var requests: [URLRequest] = []
  var responses: [HTTPResponse]
  init(_ responses: [HTTPResponse]) { self.responses = responses }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw RemoteError.protocolError }
    return responses.removeFirst()
  }
}

private func auditProvider(_ transport: AuditTransport) -> S3Provider {
  S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: "https://audit.invalid")!, region: "us-east-1", bucket: "bucket",
      accessKey: "test", secretKey: "test"), transport: transport, retrySleep: { _ in })
}

private func auditListing(_ keys: [String], truncated: Bool = false) -> HTTPResponse {
  let contents = keys.map { "<Contents><Key>\($0)</Key><Size>1</Size></Contents>" }.joined()
  return HTTPResponse(
    status: 200,
    body: Data(
      ("<ListBucketResult>\(contents)<IsTruncated>\(truncated)</IsTruncated>"
        + "<NextContinuationToken>next</NextContinuationToken></ListBucketResult>").utf8))
}

@Test func s3RangeAcceptsServerClippingAtEOF() {
  #expect(S3Provider.validContentRange("bytes 8-9/10", requested: 8..<20))
  #expect(S3Provider.validContentRange("bytes 8-9/10", requested: 8..<10))
  #expect(!S3Provider.validContentRange("bytes 8-8/10", requested: 8..<20))
  #expect(!S3Provider.validContentRange("bytes 7-9/10", requested: 8..<20))
}

@Test func s3ListPreservesSignificantXMLWhitespace() throws {
  let page = try S3ListParser.parse(
    Data(
      """
      <ListBucketResult><Contents><Key> file </Key><Size> 1 </Size></Contents>
      <CommonPrefixes><Prefix> folder /</Prefix></CommonPrefixes>
      <NextContinuationToken> token </NextContinuationToken></ListBucketResult>
      """.utf8))
  #expect(page.objects.first?.key == " file ")
  #expect(page.prefixes == [" folder /"])
  #expect(page.nextToken == " token ")
}

@Test func s3DirectoryStatStopsAfterFirstMatchingObject() async throws {
  let transport = AuditTransport([
    HTTPResponse(status: 404), auditListing(["dir/a"], truncated: true),
  ])
  let provider = auditProvider(transport)
  try await provider.connect()
  #expect(try await provider.stat(try RemotePath("/dir")).isDirectory)
  let requests = await transport.requests
  #expect(requests.count == 2)
  let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
  #expect(query?.first { $0.name == "max-keys" }?.value == "1")
}

@Test func s3LargeMoveUsesMultipartCopyBeforeDeletingSource() async throws {
  let size: Int64 = 5 * 1024 * 1024 * 1024 + 1
  let source = HTTPResponse(
    status: 200,
    headers: [
      "Content-Length": "\(size)", "ETag": "\"original\"", "Content-Type": "video/mp4",
      "x-amz-meta-note": "keep",
    ])
  // 复制按最大 5 GiB 分片，不分配文件内容。
  let transport = AuditTransport([
    source, auditListing([]), HTTPResponse(status: 404), auditListing([]),
    HTTPResponse(
      status: 200,
      body: Data(
        "<Tagging><TagSet><Tag><Key> note </Key><Value>a+b</Value></Tag></TagSet></Tagging>".utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>copy</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        "<CopyPartResult><LastModified>date</LastModified><ETag>\"one\"</ETag></CopyPartResult>"
          .utf8)),
    HTTPResponse(
      status: 200, body: Data("<CopyPartResult><ETag>\"two\"</ETag></CopyPartResult>".utf8)),
    HTTPResponse(status: 404),
    HTTPResponse(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8)),
    HTTPResponse(status: 204),
  ])
  let provider = auditProvider(transport)
  try await provider.connect()
  try await provider.move(try RemotePath("/src"), to: try RemotePath("/dst"))
  let requests = await transport.requests
  try #require(requests.count == 11)
  let parts = requests.filter { $0.value(forHTTPHeaderField: "x-amz-copy-source-range") != nil }
  #expect(
    parts.map { $0.value(forHTTPHeaderField: "x-amz-copy-source-range") } == [
      "bytes=0-5368709119", "bytes=5368709120-5368709120",
    ])
  #expect(
    parts.allSatisfy {
      $0.value(forHTTPHeaderField: "x-amz-copy-source-if-match") == "\"original\""
    })
  #expect(requests[5].value(forHTTPHeaderField: "Content-Type") == "video/mp4")
  #expect(requests[5].value(forHTTPHeaderField: "x-amz-meta-note") == "keep")
  #expect(requests[5].value(forHTTPHeaderField: "x-amz-tagging") == "%20note%20=a%2Bb")
  #expect(requests.last?.value(forHTTPHeaderField: "If-Match") == "\"original\"")
  #expect(requests.last?.httpMethod == "DELETE")
  #expect(
    requests[9].httpBody.map { String(decoding: $0, as: UTF8.self).contains("date") } == false)
}

@Test func s3RecursiveDeleteReportsAlreadyDeletedCount() async throws {
  let transport = AuditTransport([
    HTTPResponse(status: 404), auditListing(["dir/a", "dir/b", "dir/c"]),
    HTTPResponse(status: 204), HTTPResponse(status: 403),
  ])
  let provider = auditProvider(transport)
  try await provider.connect()
  do {
    try await provider.remove(try RemotePath("/dir"), recursive: true)
    Issue.record("应报告部分删除")
  } catch {
    let partial = try #require(error as? S3PartialDeletionError)
    #expect(partial.deletedKeys == ["dir/a"])
    #expect(partial.uncertainKey == "dir/b")
    #expect(partial.unattemptedKeys == ["dir/c"])
    #expect(error.localizedDescription.contains("1"))
    #expect(error.localizedDescription.contains("3"))
  }
  #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
}

@Test func s3Retries503BeforeReturningFailure() async throws {
  let transport = AuditTransport([HTTPResponse(status: 503), HTTPResponse(status: 200)])
  let provider = auditProvider(transport)
  try await provider.connect()
  _ = try await provider.spaceInfo()
  #expect(await transport.requests.count == 2)
}

@Test(arguments: ["send", "upload", "stream"])
func s3RetryBackoffIsBoundedAndUsesInjectedClock(operation: String) async throws {
  actor Clock {
    var delays: [Duration] = []
    func wait(_ duration: Duration) { delays.append(duration) }
  }
  let clock = Clock()
  let base = AuditTransport([
    HTTPResponse(status: 503), HTTPResponse(status: 429, headers: ["Retry-After": "9"]),
    HTTPResponse(status: 503), HTTPResponse(status: 503),
  ])
  let retry = S3RetryTransport(base: base, sleep: { await clock.wait($0) })
  var request = URLRequest(url: URL(string: "https://audit.invalid/object")!)
  request.httpMethod = operation == "upload" ? "PUT" : "GET"
  let status: Int
  switch operation {
  case "send": status = try await retry.send(request).status
  case "upload": status = try await retry.upload(request).status
  default: status = try await retry.stream(request).response.status
  }
  #expect(status == 503)
  #expect(await base.requests.count == 4)
  #expect(await clock.delays == [.seconds(1), .seconds(9), .seconds(4)])
}

@Test func s3RetryDoesNotRepeatMultipartCreation() async throws {
  let base = AuditTransport([HTTPResponse(status: 503)])
  let retry = S3RetryTransport(base: base, sleep: { _ in Issue.record("不应等待后重试创建任务") })
  var request = URLRequest(url: URL(string: "https://audit.invalid/object?uploads=")!)
  request.httpMethod = "POST"
  #expect(try await retry.send(request).status == 503)
  #expect(await base.requests.count == 1)
}

@Test func s3RetryCancellationDoesNotSendAgain() async throws {
  let base = AuditTransport([HTTPResponse(status: 503)])
  let retry = S3RetryTransport(base: base, sleep: { _ in throw CancellationError() })
  let request = URLRequest(url: URL(string: "https://audit.invalid/object")!)
  await #expect(throws: CancellationError.self) { _ = try await retry.send(request) }
  #expect(await base.requests.count == 1)
}

@Test(arguments: [false, true])
func s3FailedMultipartCopyNeverDeletesSource(cleanupFails: Bool) async throws {
  let transport = AuditTransport([
    HTTPResponse(status: 200, headers: ["Content-Length": "5368709121", "ETag": "source"]),
    auditListing([]), HTTPResponse(status: 404), auditListing([]),
    HTTPResponse(status: 200, body: Data("<Tagging><TagSet/></Tagging>".utf8)),
    HTTPResponse(
      status: 200,
      body: Data(
        "<InitiateMultipartUploadResult><UploadId>copy</UploadId></InitiateMultipartUploadResult>"
          .utf8)),
    HTTPResponse(status: 200, body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)),
    HTTPResponse(status: cleanupFails ? 403 : 204),
  ])
  let provider = auditProvider(transport)
  try await provider.connect()
  do {
    try await provider.move(try RemotePath("/src"), to: try RemotePath("/dst"))
    Issue.record("复制错误必须失败")
  } catch {
    if cleanupFails {
      let detail = try #require(error as? S3CopyCleanupError)
      #expect(detail.underlyingError as? RemoteError == .posix(EACCES))
      #expect(detail.cleanupError as? RemoteError == .posix(EACCES))
    } else {
      #expect(error as? RemoteError == .posix(EACCES))
    }
  }
  let requests = await transport.requests
  let deletes = requests.filter { $0.httpMethod == "DELETE" }
  #expect(deletes.count == 1)
  #expect(deletes.first?.url?.path == "/bucket/dst")
  #expect(deletes.first?.url?.query == "uploadId=copy")
  #expect(requests.filter { $0.httpMethod == "PUT" }.count == 1)
}

@Test func s3MalformedMultipartXMLCannotSupplyAnUploadID() {
  #expect(
    S3MultipartParser.value(named: "UploadId", in: Data("<Result><UploadId>x</UploadId>".utf8))
      == nil)
  #expect(
    S3MultipartParser.value(
      named: "UploadId", in: Data("<Result><Other>y</Other><UploadId>x</UploadId></Result>".utf8))
      == "x")
}

@Test(arguments: [8..<20, 10..<20, 20..<30])
func s3ReadReturnsOnlyRemainingBytesAtEOF(range: Range<Int64>) async throws {
  let response =
    range.lowerBound < 10
    ? HTTPResponse(status: 206, headers: ["Content-Range": "bytes 8-9/10"], body: Data("ok".utf8))
    : HTTPResponse(status: 416, headers: ["Content-Range": "bytes */10"])
  let transport = AuditTransport([response])
  let provider = auditProvider(transport)
  try await provider.connect()
  var received = Data()
  for try await chunk in try await provider.read(try RemotePath("/file"), range: range) {
    received.append(chunk)
  }
  #expect(received == (range.lowerBound < 10 ? Data("ok".utf8) : Data()))
}
