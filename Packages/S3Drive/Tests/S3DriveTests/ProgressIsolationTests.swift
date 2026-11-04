import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import S3Drive

private actor ProgressTransport: HTTPTransport {
  let entered = TestEvent()
  let released = TestEvent()

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    HTTPResponse(status: request.httpMethod == "HEAD" ? 404 : 200)
  }

  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.lastPathComponent == "first" {
      entered.signal()
      try await released.wait()
    }
    return HTTPResponse(status: 200)
  }
}

@Test func concurrentUploadsKeepTheirInitialProgressCallback() async throws {
  let transport = ProgressTransport()
  let provider = S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: "https://progress.example.invalid")!, region: "test",
      bucket: "bucket", accessKey: UUID().uuidString, secretKey: "test"), transport: transport)
  try await provider.connect()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let firstFile = directory.appendingPathComponent("first")
  let secondFile = directory.appendingPathComponent("second")
  try Data(repeating: 1, count: 3).write(to: firstFile)
  try Data(repeating: 2, count: 7).write(to: secondFile)
  let firstProgress = Mutex<[Int64]>([])
  let secondProgress = Mutex<[Int64]>([])
  await provider.onProgress { completed, _ in firstProgress.withLock { $0.append(completed) } }
  let first = Task { try await provider.write(RemotePath("/first"), from: firstFile) }
  try await transport.entered.wait()
  await provider.onProgress { completed, _ in secondProgress.withLock { $0.append(completed) } }
  try await provider.write(RemotePath("/second"), from: secondFile)
  transport.released.signal()
  try await first.value
  #expect(firstProgress.withLock { $0 } == [3])
  #expect(secondProgress.withLock { $0 } == [7])
}
