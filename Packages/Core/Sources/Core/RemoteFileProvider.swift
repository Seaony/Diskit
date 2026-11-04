import Foundation

public protocol RemoteFileProvider: Sendable {
  var capabilities: ProviderCapabilities { get }
  func connect() async throws
  func disconnect() async
  func spaceInfo() async throws -> SpaceInfo
  func list(_ path: RemotePath) async throws -> [RemoteItem]
  func stat(_ path: RemotePath) async throws -> RemoteItem
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  >
  func write(_ path: RemotePath, from localFile: URL) async throws
  func makeDirectory(_ path: RemotePath) async throws
  func remove(_ path: RemotePath, recursive: Bool) async throws
  func move(_ from: RemotePath, to: RemotePath) async throws
}

extension RemoteFileProvider {
  public func ensureMissing(_ path: RemotePath) async throws {
    do {
      _ = try await stat(path)
      throw RemoteError.posix(EEXIST)
    } catch RemoteError.posix(ENOENT) {
    } catch RemoteError.http(404) {}
  }
}
