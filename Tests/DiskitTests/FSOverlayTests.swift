import Core
import FSKit
import Foundation
import Testing

private actor FSOverlayProvider: RemoteFileProvider {
  nonisolated let capabilities = ProviderCapabilities(
    canWrite: false, canRename: false, canMove: false, canDelete: false, supportsRangeRead: true)
  private var mutations = 0
  func mutationCount() -> Int { mutations }
  func connect() async throws {}
  func disconnect() async {}
  func spaceInfo() async throws -> SpaceInfo { SpaceInfo(total: 1000, used: 100) }
  func stat(_ path: RemotePath) async throws -> RemoteItem {
    guard path.value == "/" || path.value == "/photo.jpg" else { throw RemoteError.posix(ENOENT) }
    return RemoteItem(path: path, name: path.basename, isDirectory: path.value == "/", size: 0,
                      modified: Date(timeIntervalSince1970: 100))
  }
  func list(_ path: RemotePath) async throws -> [RemoteItem] { [try await stat(RemotePath("/photo.jpg"))] }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func write(_ path: RemotePath, from localFile: URL) async throws {
    mutations += 1; throw RemoteError.posix(EROFS)
  }
  func makeDirectory(_ path: RemotePath) async throws {
    mutations += 1; throw RemoteError.posix(EROFS)
  }
  func remove(_ path: RemotePath, recursive: Bool) async throws {
    mutations += 1; throw RemoteError.posix(EROFS)
  }
  func move(_ from: RemotePath, to: RemotePath) async throws {
    mutations += 1; throw RemoteError.posix(EROFS)
  }
}

private struct FSOverlayReply: Sendable {
  let data: Data?
  let names: [Data]?
  let errorDomain: String?
  let errorCode: Int?

  init(data: Data? = nil, names: [Data]? = nil, error: Error?) {
    self.data = data
    self.names = names
    errorDomain = error.map { ($0 as NSError).domain }
    errorCode = error.map { ($0 as NSError).code }
  }
}

private func fsOverlaySet(_ volume: DiskitRemoteVolume, name: FSFileName, value: Data?,
                         item: DiskitRemoteItem, policy: FSVolume.SetXattrPolicy) async -> FSOverlayReply {
  await withCheckedContinuation { continuation in
    volume.setXattr(named: name, to: value, on: item, policy: policy) { error in
      continuation.resume(returning: FSOverlayReply(error: error))
    }
  }
}

private func fsOverlayGet(_ volume: DiskitRemoteVolume, name: FSFileName,
                         item: DiskitRemoteItem) async -> FSOverlayReply {
  await withCheckedContinuation { continuation in
    volume.getXattr(named: name, of: item) { data, error in
      continuation.resume(returning: FSOverlayReply(data: data, error: error))
    }
  }
}

private func fsOverlayList(_ volume: DiskitRemoteVolume,
                          item: DiskitRemoteItem) async -> FSOverlayReply {
  await withCheckedContinuation { continuation in
    volume.listXattrs(of: item) { names, error in
      continuation.resume(returning: FSOverlayReply(names: names?.map(\.data), error: error))
    }
  }
}

@Test(arguments: ["/", "/photo.jpg"])
func fsOverlayCallbacksPreserveRootAndFileAttributesOnReadOnlyVolumes(path rawPath: String) async throws {
  let cache = FileManager.default.temporaryDirectory.appending(path: "FSOverlay-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: cache) }
  let provider = FSOverlayProvider()
  let connection = Connection(kind: .lanzou, name: "Read only")
  let backend = RemoteVolumeBackend(provider: provider, connectionID: connection.id,
    kind: connection.kind, cacheRoot: cache, replacesExisting: false)
  let space = try await backend.connect()
  let volume = DiskitRemoteVolume(connection: connection, backend: backend, space: space)
  let path = try RemotePath(rawPath)
  let remote = try await provider.stat(path)
  let item = DiskitRemoteItem(id: path.value == "/" ? FSItem.Identifier.rootDirectory.rawValue : 3,
    remote: remote, parentID: FSItem.Identifier.rootDirectory.rawValue, writable: false)
  let name = FSFileName(string: "com.apple.FinderInfo")
  let contents = Data([0, 0, 255, 17, 0, 1])
  #expect(volume.maximumXattrSize >= contents.count)

  let missing = await fsOverlayGet(volume, name: name, item: item)
  #expect(missing.data == nil)
  #expect(missing.errorDomain == NSPOSIXErrorDomain)
  #expect(missing.errorCode == Int(ENOATTR))
  let missingReplacement = await fsOverlaySet(volume, name: name, value: contents,
    item: item, policy: .mustReplace)
  #expect(missingReplacement.errorCode == Int(ENOATTR))

  let created = await fsOverlaySet(volume, name: name, value: contents, item: item, policy: .mustCreate)
  #expect(created.errorCode == nil)
  let fetched = await fsOverlayGet(volume, name: name, item: item)
  #expect(fetched.errorCode == nil)
  #expect(fetched.data == contents)
  let listed = await fsOverlayList(volume, item: item)
  #expect(listed.errorCode == nil)
  #expect(listed.names == [name.data])

  let duplicate = await fsOverlaySet(volume, name: name, value: Data([42]), item: item, policy: .mustCreate)
  #expect(duplicate.errorDomain == NSPOSIXErrorDomain)
  #expect(duplicate.errorCode == Int(EEXIST))
  let unchanged = await fsOverlayGet(volume, name: name, item: item)
  #expect(unchanged.data == contents)
  let replaced = await fsOverlaySet(volume, name: name, value: Data([9]), item: item, policy: .mustReplace)
  #expect(replaced.errorCode == nil)
  #expect(await fsOverlayGet(volume, name: name, item: item).data == Data([9]))
  let reset = await fsOverlaySet(volume, name: name, value: Data(), item: item, policy: .alwaysSet)
  #expect(reset.errorCode == nil)
  #expect(await fsOverlayGet(volume, name: name, item: item).data == Data())
  let removed = await fsOverlaySet(volume, name: name, value: nil, item: item, policy: .delete)
  #expect(removed.errorCode == nil)
  #expect(await fsOverlayList(volume, item: item).names == [])
  let removeMissing = await fsOverlaySet(volume, name: name, value: nil, item: item, policy: .delete)
  #expect(removeMissing.errorCode == Int(ENOATTR))
  #expect(await provider.mutationCount() == 0)
  await backend.disconnect()
}
