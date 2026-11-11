import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private let volumeFullAccess = ProviderCapabilities(
  canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

private actor VolumeProvider: RemoteFileProvider {
  nonisolated let capabilities: ProviderCapabilities
  var files: [RemotePath: Data] = [:]
  var modifiedDates: [RemotePath: Date] = [:]
  var folders: Set<RemotePath> = [try! RemotePath("/")]
  var events: [String] = []
  var writeFails = false
  var moveFails = false
  var disconnected = false
  var rejectsExisting: Bool
  var slowListing = false
  var listing: [RemoteItem]?
  var activeLists = 0
  var peakLists = 0

  init(capabilities: ProviderCapabilities = volumeFullAccess, rejectsExisting: Bool = false) {
    self.capabilities = capabilities
    self.rejectsExisting = rejectsExisting
  }
  func put(_ path: String, data: String) throws { files[try RemotePath(path)] = Data(data.utf8) }
  func content(_ path: String) throws -> Data? { files[try RemotePath(path)] }
  func recorded() -> [String] { events }
  func resetEvents() { events = [] }
  func failWrites(_ enabled: Bool) { writeFails = enabled }
  func failMoves(_ enabled: Bool) { moveFails = enabled }
  func loseConnection() { disconnected = true }
  func delayListing() { slowListing = true }
  func setListing(_ items: [RemoteItem]) { listing = items }
  func maximumLists() -> Int { peakLists }
  func connect() async throws { disconnected = false }
  func disconnect() async { disconnected = true }
  func spaceInfo() async throws -> SpaceInfo { SpaceInfo(total: 1000, used: 100) }

  func item(_ path: RemotePath) throws -> RemoteItem {
    if let data = files[path] {
      return RemoteItem(
        path: path, name: path.basename, isDirectory: false, size: Int64(data.count),
        modified: modifiedDates[path] ?? Date(timeIntervalSince1970: 100))
    }
    if folders.contains(path) {
      return RemoteItem(
        path: path, name: path.basename, isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 100))
    }
    throw RemoteError.posix(ENOENT)
  }
  func checkConnection() throws {
    if disconnected { throw URLError(.networkConnectionLost) }
  }
  func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try checkConnection()
    events.append("list:\(path)")
    activeLists += 1
    peakLists = max(peakLists, activeLists)
    defer { activeLists -= 1 }
    if slowListing { try await Task.sleep(for: .milliseconds(20)) }
    if let listing { return listing }
    return try (Array(files.keys) + Array(folders)).filter { $0 != path && $0.parent == path }.map(
      item)
  }
  func stat(_ path: RemotePath) async throws -> RemoteItem {
    try checkConnection()
    events.append("stat:\(path)")
    return try item(path)
  }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    try checkConnection()
    events.append("read:\(path):\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "all")")
    guard let data = files[path] else { throw RemoteError.posix(ENOENT) }
    let slice: Data
    if let range {
      let lower = min(data.count, Int(range.lowerBound))
      slice = data.subdata(in: lower..<min(data.count, Int(range.upperBound)))
    } else {
      slice = data
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(slice.prefix(2))
      if slice.count > 2 { continuation.yield(slice.dropFirst(2)) }
      continuation.finish()
    }
  }
  func write(_ path: RemotePath, from localFile: URL) async throws {
    try checkConnection()
    events.append("upload:\(path)")
    if writeFails { throw RemoteError.posix(ENOSPC) }
    if rejectsExisting, files[path] != nil { throw RemoteError.posix(EEXIST) }
    files[path] = try Data(contentsOf: localFile)
    modifiedDates[path] = try localFile.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }
  func makeDirectory(_ path: RemotePath) async throws {
    try checkConnection()
    events.append("mkdir:\(path)")
    folders.insert(path)
  }
  func remove(_ path: RemotePath, recursive: Bool) async throws {
    try checkConnection()
    events.append("remove:\(path)")
    if folders.contains(path) {
      let children = files.keys.filter { RemoteVolumeBackend.contains(path, $0) }
      if !recursive, !children.isEmpty { throw RemoteError.posix(ENOTEMPTY) }
      for child in children { files.removeValue(forKey: child) }
      folders.remove(path)
    } else if files.removeValue(forKey: path) == nil {
      throw RemoteError.posix(ENOENT)
    }
  }
  func move(_ from: RemotePath, to: RemotePath) async throws {
    try checkConnection()
    events.append("move:\(from):\(to)")
    if moveFails { throw RemoteError.posix(EACCES) }
    guard files[to] == nil, !folders.contains(to) else { throw RemoteError.posix(EEXIST) }
    if let data = files.removeValue(forKey: from) {
      files[to] = data
    } else if folders.remove(from) != nil {
      folders.insert(to)
    } else {
      throw RemoteError.posix(ENOENT)
    }
  }
}

private struct VolumeFixture {
  let root: URL
  let provider: VolumeProvider
  let backend: RemoteVolumeBackend

  init(
    capabilities: ProviderCapabilities = volumeFullAccess, replacesExisting: Bool = true,
    root: URL? = nil, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024,
    kind: ConnectionKind = .androidUSB, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.root =
      root
      ?? FileManager.default.temporaryDirectory.appending(path: "RemoteVolume-" + UUID().uuidString)
    provider = VolumeProvider(capabilities: capabilities, rejectsExisting: !replacesExisting)
    backend = RemoteVolumeBackend(
      provider: provider, connectionID: UUID(), kind: kind, cacheRoot: self.root,
      replacesExisting: replacesExisting, cacheLimit: cacheLimit, now: now)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func path(_ value: String) throws -> RemotePath { try RemotePath(value) }
}

@Test func remoteVolumeDuplicateProviderPathsReturnConflictWithoutChoosingAnItem() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  let path = try fixture.path("/同名文件")
  let first = RemoteItem(
    path: path, name: "同名文件", isDirectory: false, size: 1, modified: .distantPast)
  let second = RemoteItem(
    path: path, name: "同名文件", isDirectory: false, size: 2, modified: .distantPast)
  await fixture.provider.setListing([first, second])
  _ = try await fixture.backend.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
}

@Test func remoteVolumeDeviceAndCloudDirectoryTTLAndMutationInvalidation() async throws {
  for (kind, ttl) in [(ConnectionKind.androidUSB, 5.0), (.aliyunDrive, 30.0)] {
    let clock = Mutex(Date(timeIntervalSince1970: 100))
    let fixture = VolumeFixture(kind: kind, now: { clock.withLock { $0 } })
    defer { fixture.clean() }
    _ = try await fixture.backend.connect()
    let root = try fixture.path("/")
    try await fixture.backend.open(root, writable: false)
    _ = try await fixture.backend.list(root)
    clock.withLock { $0 += ttl - 1 }
    _ = try await fixture.backend.list(root)
    #expect(await fixture.provider.recorded().filter { $0 == "list:/" }.count == 1)
    clock.withLock { $0 += 2 }
    _ = try await fixture.backend.list(root)
    #expect(await fixture.provider.recorded().filter { $0 == "list:/" }.count == 2)
    let path = try fixture.path("/new")
    _ = try await fixture.backend.createFile(path)
    #expect(try await fixture.backend.list(root).map(\.name) == ["new"])
    _ = try await fixture.backend.write(path, offset: 0, data: Data("new".utf8))
    try await fixture.backend.close(path)
    #expect(try await fixture.backend.list(root).first?.size == 3)
    try await fixture.backend.move(path, to: fixture.path("/renamed"))
    #expect(try await fixture.backend.list(root).map(\.name) == ["renamed"])
    try await fixture.backend.remove(fixture.path("/renamed"), recursive: false)
    #expect(try await fixture.backend.list(root).isEmpty)
    try await fixture.backend.close(root)
  }
}

@Test func remoteVolumeRangeReadsAvoidWholeDownloadAndWholeReadsReuseDiskCache() async throws {
  for ranged in [true, false] {
    var capabilities = volumeFullAccess
    capabilities.supportsRangeRead = ranged
    let fixture = VolumeFixture(capabilities: capabilities)
    defer { fixture.clean() }
    try await fixture.provider.put("/file", data: "abcdefgh")
    try await fixture.provider.put("/empty", data: "")
    _ = try await fixture.backend.connect()
    let path = try fixture.path("/file")
    #expect(try await fixture.backend.read(path, offset: 2, length: 3) == Data("cde".utf8))
    #expect(try await fixture.backend.read(path, offset: 6, length: 8) == Data("gh".utf8))
    #expect(try await fixture.backend.read(path, offset: 8, length: 1).isEmpty)
    #expect(try await fixture.backend.read(fixture.path("/empty"), offset: 0, length: 1).isEmpty)
    let reads = await fixture.provider.recorded().filter { $0.hasPrefix("read:") }
    #expect(
      reads
        == (ranged ? ["read:/file:2-5", "read:/file:6-8"] : ["read:/file:all", "read:/empty:all"]))
  }
}

@Test func remoteVolumeReadCacheLimitCoversAllConnectionsAndEvictsLeastRecent() async throws {
  var capabilities = volumeFullAccess
  capabilities.supportsRangeRead = false
  let first = VolumeFixture(capabilities: capabilities, cacheLimit: 6)
  let second = VolumeFixture(capabilities: capabilities, root: first.root, cacheLimit: 6)
  defer { first.clean() }
  try await first.provider.put("/first", data: "1234")
  try await second.provider.put("/second", data: "5678")
  _ = try await first.backend.connect()
  _ = try await second.backend.connect()
  let firstPath = try first.path("/first")
  _ = try await first.backend.read(firstPath, offset: 0, length: 1)
  _ = try await second.backend.read(second.path("/second"), offset: 0, length: 1)
  _ = try await first.backend.read(firstPath, offset: 1, length: 2)
  #expect(await first.provider.recorded().filter { $0 == "read:/first:all" }.count == 2)
  let enumerator = FileManager.default.enumerator(
    at: first.root, includingPropertiesForKeys: [.fileSizeKey])!
  let cached = (enumerator.allObjects as! [URL]).filter { $0.pathExtension == "data" }
  let total = try cached.reduce(0) {
    $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
  }
  #expect(total <= 6)
}

@Test func remoteVolumeWritesUploadAtFlushAndCloseAndKeepFailedLocalContent() async throws {
  let fixture = VolumeFixture()
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/file")
  _ = try await fixture.backend.createFile(path)
  try await fixture.backend.open(path, writable: false)
  try await fixture.backend.open(path, writable: true)
  _ = try await fixture.backend.write(path, offset: 2, data: Data("new".utf8))
  #expect(try await fixture.provider.content("/file") == nil)
  try await fixture.backend.flush(path)
  #expect(try await fixture.provider.content("/file") == Data([0, 0]) + Data("new".utf8))
  try await fixture.backend.resize(path, size: 3)
  let modification = Date(timeIntervalSince1970: 1_000)
  try await fixture.backend.setModifiedDate(path, date: modification)
  #expect(try await fixture.backend.stat(path).modified == modification)
  await fixture.provider.failWrites(true)
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.close(path) }
  let retained = try #require(await fixture.backend.pendingWriteFiles[path])
  #expect(try Data(contentsOf: retained) == Data([0, 0, 110]))
  await fixture.provider.failWrites(false)
  try await fixture.backend.close(path)
  #expect(await fixture.backend.pendingWriteFiles.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: retained.path))
  #expect(try await fixture.provider.content("/file") == Data([0, 0, 110]))
  #expect(try await fixture.provider.stat(path).modified == modification)
}

@Test func remoteVolumeReadOnlyAndLostConnectionReturnPOSIXErrors() async throws {
  let capabilities = ProviderCapabilities(
    canWrite: false, canRename: false, canMove: false, canDelete: false, supportsRangeRead: true)
  let fixture = VolumeFixture(capabilities: capabilities)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/file")
  await #expect(throws: RemoteError.posix(EROFS)) { _ = try await fixture.backend.createFile(path) }
  await #expect(throws: RemoteError.posix(EROFS)) {
    _ = try await fixture.backend.makeDirectory(path)
  }
  await #expect(throws: RemoteError.posix(EROFS)) {
    try await fixture.backend.remove(path, recursive: false)
  }
  await #expect(throws: RemoteError.posix(EROFS)) {
    try await fixture.backend.move(path, to: fixture.path("/other"))
  }
  await fixture.provider.loseConnection()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.read(path, offset: 0, length: 2)
  }
}

@Test func remoteVolumeSerializesProviderRequestsAcrossActorSuspension() async throws {
  let fixture = VolumeFixture()
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  await fixture.provider.delayListing()
  async let first = fixture.backend.list(fixture.path("/one"))
  async let second = fixture.backend.list(fixture.path("/two"))
  _ = try await (first, second)
  #expect(await fixture.provider.maximumLists() == 1)
}

@Test func remoteVolumeNonOverwritingProviderUploadsAndChecksBeforeDeletingOriginal() async throws {
  let fixture = VolumeFixture(replacesExisting: false)
  defer { fixture.clean() }
  try await fixture.provider.put("/file", data: "original")
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/file")
  try await fixture.backend.open(path, writable: true)
  try await fixture.backend.resize(path, size: 0)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("replacement".utf8))
  await fixture.provider.resetEvents()
  try await fixture.backend.close(path)
  let events = await fixture.provider.recorded()
  let upload = try #require(events.firstIndex { $0.hasPrefix("upload:/.file.kayoi-upload-") })
  let temporary = String(events[upload].dropFirst("upload:".count))
  let check = try #require(events.firstIndex(of: "stat:" + temporary))
  let remove = try #require(events.firstIndex(of: "remove:/file"))
  let move = try #require(events.firstIndex(of: "move:" + temporary + ":/file"))
  #expect(upload < check && check < remove && remove < move)
  #expect(try await fixture.provider.content("/file") == Data("replacement".utf8))
}

@Test func remoteVolumeFailedReplacementRetainsSourceAndLocalFileForRecovery() async throws {
  let fixture = VolumeFixture(replacesExisting: false)
  defer { fixture.clean() }
  try await fixture.provider.put("/file", data: "old")
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/file")
  try await fixture.backend.open(path, writable: true)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("new".utf8))
  await fixture.provider.failMoves(true)
  await #expect(throws: RemoteError.posix(EACCES)) { try await fixture.backend.close(path) }
  let retained = try #require(await fixture.backend.pendingWriteFiles[path])
  #expect(try Data(contentsOf: retained) == Data("new".utf8))
  let temporary = try #require(await fixture.backend.recoveryPaths.first)
  #expect(try await fixture.provider.content(temporary.value) == Data("new".utf8))
  #expect(try await fixture.backend.list(fixture.path("/")).map(\.name) == ["file"])
  await fixture.provider.failMoves(false)
  try await fixture.backend.close(path)
  #expect(try await fixture.provider.content("/file") == Data("new".utf8))
}

@Test func remoteVolumeRenameReplacementKeepsOriginalUntilNewSourceWasUploaded() async throws {
  let fixture = VolumeFixture(replacesExisting: false)
  defer { fixture.clean() }
  try await fixture.provider.put("/old", data: "old")
  _ = try await fixture.backend.connect()
  let source = try fixture.path("/editor-temp")
  let target = try fixture.path("/old")
  _ = try await fixture.backend.createFile(source)
  _ = try await fixture.backend.write(source, offset: 0, data: Data("updated".utf8))
  await fixture.provider.resetEvents()
  await fixture.provider.failMoves(true)
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await fixture.backend.move(source, to: target, replacing: true)
  }
  let retained = try #require(await fixture.backend.pendingWriteFiles[source])
  try await fixture.backend.close(source)
  #expect(FileManager.default.fileExists(atPath: retained.path))
  #expect(try await fixture.provider.content("/editor-temp") == Data("updated".utf8))
  let events = await fixture.provider.recorded()
  let uploaded = try #require(events.firstIndex(of: "upload:/editor-temp"))
  let checked = try #require(events[(uploaded + 1)...].firstIndex(of: "stat:/editor-temp"))
  let removed = try #require(events.firstIndex(of: "remove:/old"))
  #expect(uploaded < checked && checked < removed)
  await fixture.provider.failMoves(false)
  try await fixture.backend.move(source, to: target, replacing: true)
  #expect(try await fixture.provider.content("/old") == Data("updated".utf8))
  try await fixture.backend.close(target)
}

@Test func remoteVolumeExistingWriteRequiresSafeReplacementCapabilities() async throws {
  var capabilities = volumeFullAccess
  capabilities.canRename = false
  let fixture = VolumeFixture(capabilities: capabilities, replacesExisting: false)
  defer { fixture.clean() }
  try await fixture.provider.put("/existing", data: "keep")
  _ = try await fixture.backend.connect()
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await fixture.backend.open(fixture.path("/existing"), writable: true)
  }
  let fresh = try fixture.path("/fresh")
  _ = try await fixture.backend.createFile(fresh)
  _ = try await fixture.backend.write(fresh, offset: 0, data: Data("new".utf8))
  try await fixture.backend.close(fresh)
  #expect(try await fixture.provider.content("/existing") == Data("keep".utf8))
  #expect(try await fixture.provider.content("/fresh") == Data("new".utf8))
}
