import Foundation
import Testing

@testable import Core

@Test func remotePathParentAndBasenamePreserveNormalizedNames() throws {
  for (value, parent, name) in [
    ("/", "/", ""), ("/a", "/", "a"), ("/a//b/", "/a", "b"), ("/空 格/a+b", "/空 格", "a+b"),
  ] {
    let path = try RemotePath(value)
    #expect(path.parent.value == parent)
    #expect(path.basename == name)
  }
}

@Test func sharedContentRangeRequiresExactBoundsAndTotal() {
  #expect(HTTPContentRange.matches("bytes 10-19/100", requested: 10..<20, size: 100))
  for header in [
    nil, "items 10-19/100", "bytes 0-19/100", "bytes 10-18/100", "bytes 10-19/99", "bytes 10-19/*",
    "bytes 10-19/100/200",
  ] {
    #expect(!HTTPContentRange.matches(header, requested: 10..<20, size: 100))
  }
}

private struct ExistenceProvider: RemoteFileProvider {
  let failure: RemoteError?
  var capabilities: ProviderCapabilities {
    .init(canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: false)
  }
  func connect() async throws {}
  func disconnect() async {}
  func stat(_ path: RemotePath) async throws -> RemoteItem {
    if let failure { throw failure }
    return RemoteItem(
      path: path, name: path.basename, isDirectory: false, size: 0, modified: .distantPast)
  }
  func spaceInfo() async throws -> SpaceInfo { throw RemoteError.unsupported }
  func list(_ path: RemotePath) async throws -> [RemoteItem] { throw RemoteError.unsupported }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > { throw RemoteError.unsupported }
  func write(_ path: RemotePath, from localFile: URL) async throws { throw RemoteError.unsupported }
  func makeDirectory(_ path: RemotePath) async throws { throw RemoteError.unsupported }
  func remove(_ path: RemotePath, recursive: Bool) async throws { throw RemoteError.unsupported }
  func move(_ from: RemotePath, to: RemotePath) async throws { throw RemoteError.unsupported }
}

@Test func sharedMissingCheckPropagatesAllNonMissingFailures() async throws {
  let path = try RemotePath("/item")
  try await ExistenceProvider(failure: .posix(ENOENT)).ensureMissing(path)
  try await ExistenceProvider(failure: .http(404)).ensureMissing(path)
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await ExistenceProvider(failure: nil).ensureMissing(path)
  }
  for error in [RemoteError.unauthorized, .http(500), .protocolError, .posix(ETIMEDOUT)] {
    await #expect(throws: error) { try await ExistenceProvider(failure: error).ensureMissing(path) }
  }
}
