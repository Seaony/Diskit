import Core
import Foundation
import Testing

@testable import TianyiDrive

private actor TianyiUploadProbe: HTTPTransport {
  var uploads = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    Issue.record("文件块走了普通请求计时")
    return HTTPResponse(status: 200)
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    uploads += 1
    #expect(request.httpMethod == "PUT")
    #expect(request.httpBody == Data([1, 2]))
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    return HTTPResponse(status: 200)
  }
}

@Test func tianyiFileChunkUsesUploadProgressDeadlineRoute() async throws {
  let probe = TianyiUploadProbe()
  let session = TianyiSession(secretKey: "local", secrets: MemorySecretStore(), transport: probe)
  _ = try await session.uploadChunk(
    url: URL(string: "https://upload.example.invalid/file")!, headers: [:], body: Data([1, 2]))
  #expect(await probe.uploads == 1)
}
