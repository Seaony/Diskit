import Foundation
import Testing

@testable import Core

private let metadataNames = [
  ".DS_Store", ".VolumeIcon.icns", ".Spotlight-V100", ".fseventsd", ".Trashes",
]

private struct MetadataFixture {
  let root = FileManager.default.temporaryDirectory.appending(path: "MetadataOverlay-" + UUID().uuidString)
  let connectionID = UUID()
  var store: LocalMetadataOverlay { LocalMetadataOverlay(cacheRoot: root, connectionID: connectionID) }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private func metadataErrno(_ operation: () throws -> Void) -> Int? {
  do {
    try operation()
    return nil
  } catch {
    let value = error as NSError
    #expect(value.domain == NSPOSIXErrorDomain)
    return value.code
  }
}

private func metadataErrno(_ operation: () async throws -> Void) async -> Int? {
  do {
    try await operation()
    return nil
  } catch {
    let value = error as NSError
    #expect(value.domain == NSPOSIXErrorDomain)
    return value.code
  }
}

@Test func metadataOverlayXattrsPersistOnRootAndFilesAndStayWithinTheirConnection() throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let root = try RemotePath("/")
  let photo = try RemotePath("/Photos/photo.jpg")
  let finderInfo = Data("com.apple.FinderInfo".utf8)
  let resourceFork = Data("com.apple.ResourceFork".utf8)
  let value = Data([0, 255, 17, 0, 42])
  try fixture.store.setXattr(named: finderInfo, to: value, on: root, policy: .create)
  try fixture.store.setXattr(named: resourceFork, to: Data(), on: photo, policy: .set)

  let reopened = fixture.store
  #expect(try reopened.getXattr(named: finderInfo, of: root) == value)
  #expect(try reopened.listXattrs(of: root) == [finderInfo])
  #expect(try reopened.getXattr(named: resourceFork, of: photo).isEmpty)
  #expect(try reopened.listXattrs(of: photo) == [resourceFork])

  let other = LocalMetadataOverlay(cacheRoot: fixture.root, connectionID: UUID())
  #expect(try other.listXattrs(of: root).isEmpty)
  #expect(metadataErrno { _ = try other.getXattr(named: finderInfo, of: root) } == Int(ENOATTR))
  try other.setXattr(named: finderInfo, to: Data("other".utf8), on: root, policy: .set)
  #expect(try fixture.store.getXattr(named: finderInfo, of: root) == value)
}

@Test func metadataOverlayXattrPoliciesReturnConflictsAndMissingAttributeErrors() throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let path = try RemotePath("/file.txt")
  let name = Data("com.apple.metadata:kMDItemWhereFroms".utf8)
  #expect(metadataErrno { _ = try fixture.store.getXattr(named: name, of: path) } == Int(ENOATTR))
  #expect(metadataErrno {
    try fixture.store.setXattr(named: name, to: Data([1]), on: path, policy: .replace)
  } == Int(ENOATTR))
  try fixture.store.setXattr(named: name, to: Data([1]), on: path, policy: .create)
  #expect(metadataErrno {
    try fixture.store.setXattr(named: name, to: Data([2]), on: path, policy: .create)
  } == Int(EEXIST))
  #expect(try fixture.store.getXattr(named: name, of: path) == Data([1]))
  try fixture.store.setXattr(named: name, to: Data([3]), on: path, policy: .replace)
  #expect(try fixture.store.getXattr(named: name, of: path) == Data([3]))
  try fixture.store.setXattr(named: name, to: nil, on: path, policy: .remove)
  #expect(try fixture.store.listXattrs(of: path).isEmpty)
  #expect(metadataErrno {
    try fixture.store.setXattr(named: name, to: nil, on: path, policy: .remove)
  } == Int(ENOATTR))
  #expect(try fixture.store.listXattrs(of: path).isEmpty)
}

@Test(arguments: metadataNames)
func metadataOverlayReservedFilesAndSubtreesPersistTheirContents(name: String) throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let reserved = try RemotePath("/Photos/" + name)
  #expect(LocalMetadataOverlay.handles(reserved))
  let path: RemotePath
  if name == ".DS_Store" || name == ".VolumeIcon.icns" {
    path = reserved
  } else {
    _ = try fixture.store.makeDirectory(reserved)
    let nested = try reserved.appending("history")
    _ = try fixture.store.makeDirectory(nested)
    path = try nested.appending("entry")
    #expect(LocalMetadataOverlay.handles(path))
  }
  _ = try fixture.store.createFile(path)
  _ = try fixture.store.write(path, offset: 2, data: Data("abcdef".utf8))
  try fixture.store.resize(path, size: 6)
  let date = Date(timeIntervalSince1970: 1_000)
  try fixture.store.setModifiedDate(path, date: date)
  try fixture.store.flush(path)

  let reopened = fixture.store
  #expect(try reopened.stat(path).size == 6)
  #expect(try reopened.stat(path).modified == date)
  #expect(try reopened.read(path, offset: 0, length: 99) == Data([0, 0]) + Data("abcd".utf8))
  #expect(try reopened.read(path, offset: 3, length: 2) == Data("bc".utf8))
  #expect(try reopened.list(path.parent).map(\.name) == [path.basename])
  #expect(!LocalMetadataOverlay.handles(try RemotePath("/Photos/photo.jpg")))
}

private actor MetadataRemoteProvider: RemoteFileProvider {
  nonisolated let capabilities: ProviderCapabilities
  private var files: [RemotePath: Data] = [:]
  private var directories: Set<RemotePath> = [try! RemotePath("/")]
  private var mutations: [String] = []

  init(readOnly: Bool = false) {
    capabilities = ProviderCapabilities(canWrite: !readOnly, canRename: !readOnly,
      canMove: !readOnly, canDelete: !readOnly, supportsRangeRead: true)
  }

  func seedFile(_ path: RemotePath, contents: Data) { files[path] = contents; directories.insert(path.parent) }
  func seedDirectory(_ path: RemotePath) { directories.insert(path) }
  func recordedMutations() -> [String] { mutations }
  func contents(_ path: RemotePath) -> Data? { files[path] }
  func connect() async throws {}
  func disconnect() async {}
  func spaceInfo() async throws -> SpaceInfo { SpaceInfo(total: 1000, used: 100) }
  func stat(_ path: RemotePath) async throws -> RemoteItem {
    if let data = files[path] {
      return RemoteItem(path: path, name: path.basename, isDirectory: false,
                        size: Int64(data.count), modified: Date(timeIntervalSince1970: 100))
    }
    guard directories.contains(path) else { throw RemoteError.posix(ENOENT) }
    return RemoteItem(path: path, name: path.basename, isDirectory: true, size: 0,
                      modified: Date(timeIntervalSince1970: 100))
  }
  func list(_ path: RemotePath) async throws -> [RemoteItem] {
    var result: [RemoteItem] = []
    for child in Array(files.keys) + Array(directories) where child != path && child.parent == path {
      result.append(try await stat(child))
    }
    return result
  }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
    guard let data = files[path] else { throw RemoteError.posix(ENOENT) }
    let result = range.map { data.subdata(in: Int($0.lowerBound)..<min(data.count, Int($0.upperBound))) } ?? data
    return AsyncThrowingStream { $0.yield(result); $0.finish() }
  }
  func write(_ path: RemotePath, from localFile: URL) async throws {
    mutations.append("write:" + path.value)
    guard capabilities.canWrite else { throw RemoteError.posix(EROFS) }
    files[path] = try Data(contentsOf: localFile)
  }
  func makeDirectory(_ path: RemotePath) async throws {
    mutations.append("mkdir:" + path.value)
    guard capabilities.canWrite else { throw RemoteError.posix(EROFS) }
    directories.insert(path)
  }
  func remove(_ path: RemotePath, recursive: Bool) async throws {
    mutations.append("remove:" + path.value)
    guard capabilities.canDelete else { throw RemoteError.posix(EROFS) }
    guard files[path] != nil || directories.contains(path) else { throw RemoteError.posix(ENOENT) }
    let children = (Array(files.keys) + Array(directories)).filter {
      $0 != path && $0.value.hasPrefix(path.value + "/")
    }
    if !recursive, !children.isEmpty { throw RemoteError.posix(ENOTEMPTY) }
    for child in children + [path] { files.removeValue(forKey: child); directories.remove(child) }
  }
  func move(_ from: RemotePath, to: RemotePath) async throws {
    mutations.append("move:" + from.value + ":" + to.value)
    guard capabilities.canMove else { throw RemoteError.posix(EROFS) }
    guard files[to] == nil, !directories.contains(to) else { throw RemoteError.posix(EEXIST) }
    guard files[from] != nil || directories.contains(from) else { throw RemoteError.posix(ENOENT) }
    let movingFiles = files.filter { $0.key == from || $0.key.value.hasPrefix(from.value + "/") }
    let movingDirectories = directories.filter { $0 == from || $0.value.hasPrefix(from.value + "/") }
    for (old, data) in movingFiles {
      files.removeValue(forKey: old)
      files[try RemotePath(to.value + old.value.dropFirst(from.value.count))] = data
    }
    for old in movingDirectories {
      directories.remove(old)
      directories.insert(try RemotePath(to.value + old.value.dropFirst(from.value.count)))
    }
  }
}

private func metadataBackend(_ fixture: MetadataFixture, provider: MetadataRemoteProvider) -> RemoteVolumeBackend {
  RemoteVolumeBackend(provider: provider, connectionID: fixture.connectionID, kind: .quark,
                      cacheRoot: fixture.root, replacesExisting: true)
}

@Test func metadataBackendRoutesReservedFilesAndSubtreesWithoutRemoteMutations() async throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let provider = MetadataRemoteProvider()
  let backend = metadataBackend(fixture, provider: provider)
  _ = try await backend.connect()
  let contents = Data("local metadata".utf8)
  var paths: [RemotePath] = []
  for name in metadataNames {
    let reserved = try RemotePath("/" + name)
    if name == ".DS_Store" || name == ".VolumeIcon.icns" {
      paths.append(reserved)
    } else {
      _ = try await backend.makeDirectory(reserved)
      let nested = try reserved.appending("history")
      _ = try await backend.makeDirectory(nested)
      paths.append(try nested.appending("entry"))
    }
    let path = try #require(paths.last)
    _ = try await backend.createFile(path)
    _ = try await backend.write(path, offset: 0, data: contents)
    try await backend.close(path)
  }
  await backend.disconnect()
  let reopened = metadataBackend(fixture, provider: provider)
  _ = try await reopened.connect()
  for path in paths {
    #expect(try await reopened.stat(path).size == Int64(contents.count))
    #expect(try await reopened.read(path, offset: 0, length: 99) == contents)
  }
  let original = try RemotePath("/.Trashes/history/entry")
  let renamed = try RemotePath("/.Trashes/history/renamed")
  try await reopened.move(original, to: renamed)
  #expect(try await reopened.read(renamed, offset: 0, length: 99) == contents)
  try await reopened.remove(try RemotePath("/.Trashes"), recursive: true)
  #expect(await metadataErrno { _ = try await reopened.stat(renamed) } == Int(ENOENT))
  #expect(await provider.recordedMutations().isEmpty)
  await reopened.disconnect()
}

@Test func metadataBackendMergesLocalItemsWithoutExposingMirrorScaffoldingAndKeepsRemoteWrites() async throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let provider = MetadataRemoteProvider()
  let photos = try RemotePath("/Photos")
  let remote = try photos.appending("photo.jpg")
  await provider.seedDirectory(photos)
  await provider.seedFile(remote, contents: Data("remote".utf8))
  _ = try fixture.store.createFile(try RemotePath("/Scaffolding/.DS_Store"))
  let backend = metadataBackend(fixture, provider: provider)
  _ = try await backend.connect()
  let local = try photos.appending(".DS_Store")
  _ = try await backend.createFile(local)
  _ = try await backend.write(local, offset: 0, data: Data("finder".utf8))
  try await backend.close(local)
  #expect(try await backend.list(try RemotePath("/")).map(\.name) == ["Photos"])
  #expect(Set(try await backend.list(photos).map(\.name)) == ["photo.jpg", ".DS_Store"])
  #expect(try await backend.read(remote, offset: 1, length: 3) == Data("emo".utf8))

  let upload = try photos.appending("upload.txt")
  _ = try await backend.createFile(upload)
  _ = try await backend.write(upload, offset: 0, data: Data("uploaded".utf8))
  try await backend.close(upload)
  #expect(await provider.contents(upload) == Data("uploaded".utf8))
  #expect(await provider.recordedMutations() == ["write:/Photos/upload.txt"])
  await backend.disconnect()
}

@Test func metadataBackendMovesAndRemovesLocalMetadataWithRemoteDirectories() async throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let provider = MetadataRemoteProvider()
  let source = try RemotePath("/Photos")
  let destination = try RemotePath("/Archive")
  let photo = try source.appending("photo.jpg")
  await provider.seedDirectory(source)
  await provider.seedFile(photo, contents: Data("image".utf8))
  let backend = metadataBackend(fixture, provider: provider)
  _ = try await backend.connect()
  let attribute = Data("com.apple.FinderInfo".utf8)
  try await backend.setXattr(named: attribute, to: Data([1]), on: source, policy: .set)
  try await backend.setXattr(named: attribute, to: Data([2]), on: photo, policy: .set)
  let local = try source.appending(".DS_Store")
  _ = try await backend.createFile(local)
  _ = try await backend.write(local, offset: 0, data: Data("finder".utf8))
  try await backend.close(local)

  try await backend.move(source, to: destination)
  #expect(try await backend.getXattr(named: attribute, of: destination) == Data([1]))
  #expect(try await backend.getXattr(named: attribute, of: destination.appending("photo.jpg")) == Data([2]))
  #expect(try await backend.read(destination.appending(".DS_Store"), offset: 0, length: 99) == Data("finder".utf8))
  #expect(try fixture.store.listXattrs(of: source).isEmpty)
  #expect(metadataErrno { _ = try fixture.store.stat(local) } == Int(ENOENT))

  try await backend.remove(destination, recursive: true)
  #expect(try fixture.store.listXattrs(of: destination).isEmpty)
  #expect(try fixture.store.listXattrs(of: destination.appending("photo.jpg")).isEmpty)
  #expect(metadataErrno { _ = try fixture.store.stat(destination.appending(".DS_Store")) } == Int(ENOENT))
  #expect(await provider.recordedMutations() == ["move:/Photos:/Archive", "remove:/Archive"])
  await backend.disconnect()
}

@Test func metadataBackendReadOnlyRemoteStillAllowsLocalMetadataAndAttributes() async throws {
  let fixture = MetadataFixture()
  defer { fixture.clean() }
  let provider = MetadataRemoteProvider(readOnly: true)
  let photo = try RemotePath("/photo.jpg")
  await provider.seedFile(photo, contents: Data("image".utf8))
  let backend = metadataBackend(fixture, provider: provider)
  _ = try await backend.connect()
  #expect(await metadataErrno { _ = try await backend.write(photo, offset: 0, data: Data([1])) } == Int(EROFS))
  #expect(await metadataErrno { _ = try await backend.createFile(RemotePath("/upload")) } == Int(EROFS))
  let name = Data("com.apple.ResourceFork".utf8)
  try await backend.setXattr(named: name, to: Data([0, 1, 2]), on: photo, policy: .create)
  #expect(try await backend.getXattr(named: name, of: photo) == Data([0, 1, 2]))
  let local = try RemotePath("/.DS_Store")
  _ = try await backend.createFile(local)
  _ = try await backend.write(local, offset: 0, data: Data("finder".utf8))
  try await backend.close(local)
  #expect(try await backend.read(local, offset: 0, length: 99) == Data("finder".utf8))
  #expect(await provider.recordedMutations().isEmpty)
  #expect(await provider.contents(photo) == Data("image".utf8))
  await backend.disconnect()
}
