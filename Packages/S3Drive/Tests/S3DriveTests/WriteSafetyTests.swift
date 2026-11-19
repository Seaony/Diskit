import Core
import Foundation
import Testing

@testable import S3Drive

private actor UnconditionalObjectStore: HTTPTransport {
  var object: Data?
  var requests: [URLRequest] = []
  var uploaded = Data()
  let headStatus: Int?
  let createsDuringUpload: Bool
  init(object: Data? = nil, headStatus: Int? = nil, createsDuringUpload: Bool = false) {
    self.object = object
    self.headStatus = headStatus
    self.createsDuringUpload = createsDuringUpload
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard request.url?.host == "s3.example.com",
      request.url?.path == "/bucket/item" || request.url?.path == "/bucket/item/"
    else { return HTTPResponse(status: 404) }
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch request.httpMethod {
    case "HEAD":
      return HTTPResponse(status: headStatus ?? (object == nil ? 404 : 200))
    case "PUT":
      if query.contains(where: { $0.name == "partNumber" }) {
        uploaded.append(request.httpBody ?? Data())
        if createsDuringUpload { object = Data("other writer".utf8) }
        return HTTPResponse(status: 200, headers: ["ETag": "part"])
      }
      // 模拟忽略条件头的服务，确实覆盖原内容。
      object = request.httpBody ?? Data()
      return HTTPResponse(status: 200)
    case "POST":
      if query.contains(where: { $0.name == "uploads" }) {
        return HTTPResponse(
          status: 200,
          body: Data(
            "<InitiateMultipartUploadResult><UploadId>local</UploadId></InitiateMultipartUploadResult>"
              .utf8))
      }
      object = uploaded
      return HTTPResponse(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8))
    case "DELETE": return HTTPResponse(status: 204)
    default: return HTTPResponse(status: 500)
    }
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    throw RemoteError.protocolError
  }
}

private func safetyProvider(_ transport: UnconditionalObjectStore, multipart: Bool = false)
  -> S3Provider
{
  S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: "https://s3.example.com")!, region: "us-east-1", bucket: "bucket",
      accessKey: "test", secretKey: "test"), transport: transport,
    multipartThreshold: multipart ? 1 : 1024, partSize: 5 * 1024 * 1024)
}

@Test(arguments: ["file", "empty", "multipart", "directory"])
func s3RejectsExistingObjectWhenServiceIgnoresConditions(operation: String) async throws {
  let original = Data("keep original".utf8)
  let transport = UnconditionalObjectStore(object: original)
  let s3 = safetyProvider(transport, multipart: operation == "multipart")
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try (operation == "empty" ? Data() : Data("replacement".utf8)).write(to: file)
  try await s3.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    if operation == "directory" {
      try await s3.makeDirectory(try RemotePath("/item"))
    } else {
      try await s3.write(try RemotePath("/item"), from: file)
    }
  }
  #expect(await transport.object == original)
  #expect(await transport.requests.map(\.httpMethod) == ["HEAD"])
}

@Test(arguments: [403, 500])
func s3PreflightFailureNeverWrites(status: Int) async throws {
  let transport = UnconditionalObjectStore(headStatus: status)
  let s3 = safetyProvider(transport)
  try await s3.connect()
  let expected =
    status == 403
    ? RemoteError.posix(EACCES)
    : RemoteError.failed(EIO, LF("S3 服务出错（HTTP %@），没有返回错误说明", String(status)))
  await #expect(throws: expected) {
    try await s3.makeDirectory(try RemotePath("/item"))
  }
  #expect(await transport.object == nil)
  #expect(await transport.requests.map(\.httpMethod) == ["HEAD"])
}

@Test func s3MultipartChecksAgainBeforePublishing() async throws {
  let transport = UnconditionalObjectStore(createsDuringUpload: true)
  let s3 = safetyProvider(transport, multipart: true)
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("replacement".utf8).write(to: file)
  try await s3.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await s3.write(try RemotePath("/item"), from: file)
  }
  #expect(await transport.object == Data("other writer".utf8))
  #expect(await transport.requests.map(\.httpMethod) == ["HEAD", "POST", "PUT", "HEAD", "DELETE"])
}

@Test(arguments: ["file", "empty", "multipart", "directory"])
func s3MissingObjectIsWrittenWithConditions(operation: String) async throws {
  let transport = UnconditionalObjectStore()
  let s3 = safetyProvider(transport, multipart: operation == "multipart")
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let payload = operation == "empty" || operation == "directory" ? Data() : Data("new object".utf8)
  try payload.write(to: file)
  try await s3.connect()
  if operation == "directory" {
    try await s3.makeDirectory(try RemotePath("/item"))
  } else {
    try await s3.write(try RemotePath("/item"), from: file)
  }
  #expect(await transport.object == payload)
  let requests = await transport.requests
  #expect(
    requests.map(\.httpMethod)
      == (operation == "multipart" ? ["HEAD", "POST", "PUT", "HEAD", "POST"] : ["HEAD", "PUT"]))
  #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "*")
}
