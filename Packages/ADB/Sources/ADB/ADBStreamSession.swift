import Core
import Foundation

// 一次只开一个服务（sync:、shell:）的读写通道。直连手机用 ADBSession，
// 手机被电脑上的 adb server 占着时用 ADBServerSession 经它转发
protocol ADBStreamSession: Actor {
  var features: Set<String> { get }
  func connect() async throws
  func open(_ service: String) async throws
  func write(_ bytes: Data, timeout: TimeInterval) async throws
  func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data
  func readChunk(timeout: TimeInterval) async throws -> Data?
  func closeService() async throws
  func recoverAfterOperationError(_ error: Error) async -> Bool
  func disconnect() async
}

extension ADBStreamSession {
  func write(_ bytes: Data) async throws {
    try await write(bytes, timeout: RemoteTimeout.deviceRequest)
  }
  func readExactly(_ count: Int) async throws -> Data {
    try await readExactly(count, timeout: RemoteTimeout.deviceRequest)
  }
  func readChunk() async throws -> Data? {
    try await readChunk(timeout: RemoteTimeout.deviceRequest)
  }
}
