import Core
import FSKit
import Foundation
import Testing

private struct FSVolumeExpiredLogin: LoginRequiredFailure {
  let requiresLogin = true
}

private actor FSVolumeProvider: RemoteFileProvider {
  nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private var files: [RemotePath: Data] = [:]
  private var loginExpired = false
  private var uploadFails = false

  func replace(_ path: RemotePath, contents: Data) { files[path] = contents }
  func expireLogin() { loginExpired = true }
  func failUploads() { uploadFails = true }
  func connect() async throws {}
  func disconnect() async {}
  func spaceInfo() async throws -> SpaceInfo { SpaceInfo(total: 1000, used: 100) }

  func stat(_ path: RemotePath) async throws -> RemoteItem {
    if loginExpired { throw FSVolumeExpiredLogin() }
    if path.value == "/" {
      return RemoteItem(path: path, name: "/", isDirectory: true, size: 0,
                        modified: Date(timeIntervalSince1970: 100))
    }
    guard let contents = files[path] else { throw RemoteError.posix(ENOENT) }
    return RemoteItem(path: path, name: path.basename, isDirectory: false,
                      size: Int64(contents.count), modified: Date(timeIntervalSince1970: 100))
  }

  func list(_ path: RemotePath) async throws -> [RemoteItem] {
    var result: [RemoteItem] = []
    for key in files.keys where key.parent == path { result.append(try await stat(key)) }
    return result
  }

  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
    guard let contents = files[path] else { throw RemoteError.posix(ENOENT) }
    let data: Data
    if let range {
      let start = min(contents.count, Int(range.lowerBound))
      data = contents.subdata(in: start..<min(contents.count, Int(range.upperBound)))
    } else {
      data = contents
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(data)
      continuation.finish()
    }
  }

  func write(_ path: RemotePath, from localFile: URL) async throws {
    if uploadFails { throw RemoteError.posix(ENOSPC) }
    files[path] = try Data(contentsOf: localFile)
  }
  func makeDirectory(_ path: RemotePath) async throws { throw RemoteError.unsupported }
  func remove(_ path: RemotePath, recursive: Bool) async throws { throw RemoteError.unsupported }
  func move(_ from: RemotePath, to: RemotePath) async throws { throw RemoteError.unsupported }
}

private struct FSVolumeReply: Sendable {
  let size: UInt64?
  let errorDomain: String?
  let errorCode: Int?

  init(attributes: FSItem.Attributes? = nil, error: Error?) {
    size = attributes?.size
    errorDomain = error.map { ($0 as NSError).domain }
    errorCode = error.map { ($0 as NSError).code }
  }
}

private func attributes(of item: DiskitRemoteItem, on volume: DiskitRemoteVolume) async -> FSVolumeReply {
  let request = FSItem.GetAttributesRequest()
  request.wantedAttributes = [.size]
  return await withCheckedContinuation { continuation in
    volume.getAttributes(request, of: item) { attributes, error in
      continuation.resume(returning: FSVolumeReply(attributes: attributes, error: error))
    }
  }
}

@Test func fsVolumeAttributesRefreshRemoteChangesAndReturnLoginFailureAsAccessDenied() async throws {
  let cache = FileManager.default.temporaryDirectory.appending(path: "FSVolume-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: cache) }
  let provider = FSVolumeProvider()
  let path = try RemotePath("/file.txt")
  await provider.replace(path, contents: Data("old".utf8))
  let initial = try await provider.stat(path)
  let connection = Connection(kind: .quark, name: "Test")
  let backend = RemoteVolumeBackend(provider: provider, connectionID: connection.id,
                                    kind: connection.kind, cacheRoot: cache, replacesExisting: true)
  let space = try await backend.connect()
  let volume = DiskitRemoteVolume(connection: connection, backend: backend, space: space)
  let item = DiskitRemoteItem(id: 3, remote: initial,
                             parentID: FSItem.Identifier.rootDirectory.rawValue, writable: true)

  await provider.replace(path, contents: Data("changed outside the volume".utf8))
  let refreshed = await attributes(of: item, on: volume)
  #expect(refreshed.errorCode == nil)
  #expect(refreshed.size == UInt64("changed outside the volume".utf8.count))

  await provider.expireLogin()
  let denied = await attributes(of: item, on: volume)
  #expect(denied.errorDomain == NSPOSIXErrorDomain)
  #expect(denied.errorCode == Int(EACCES))
  await backend.disconnect()
}

@Test func fsVolumeCloseReturnsUploadErrorAndKeepsLocalContents() async throws {
  let cache = FileManager.default.temporaryDirectory.appending(path: "FSVolume-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: cache) }
  let provider = FSVolumeProvider()
  let connection = Connection(kind: .androidUSB, name: "Test")
  let backend = RemoteVolumeBackend(provider: provider, connectionID: connection.id,
                                    kind: connection.kind, cacheRoot: cache, replacesExisting: true)
  let space = try await backend.connect()
  let volume = DiskitRemoteVolume(connection: connection, backend: backend, space: space)
  let path = try RemotePath("/new.txt")
  let created = try await backend.createFile(path)
  let item = DiskitRemoteItem(id: 3, remote: created,
                             parentID: FSItem.Identifier.rootDirectory.rawValue, writable: true)
  try await backend.open(path, writable: true)
  let contents = Data("unsent contents must survive".utf8)
  _ = try await backend.write(path, offset: 0, data: contents)
  await provider.failUploads()

  let reply: FSVolumeReply = await withCheckedContinuation { continuation in
    volume.closeItem(item, modes: []) { error in
      continuation.resume(returning: FSVolumeReply(error: error))
    }
  }
  #expect(reply.errorDomain == NSPOSIXErrorDomain)
  #expect(reply.errorCode == Int(ENOSPC))
  let retained = try #require(await backend.pendingWriteFiles[path])
  #expect(try Data(contentsOf: retained) == contents)
  await backend.disconnect()
}
