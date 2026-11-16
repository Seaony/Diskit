import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private let volumeFullAccess = ProviderCapabilities(
  canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

private actor VolumeReadControl {
  let started = TestEvent()
  let cancelled = TestEvent()
  let finished = TestEvent()
  private let data: Data
  private var step = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(data: Data) { self.data = data }

  func next() async throws -> Data? {
    if step == 0 {
      step = 1
      return Data(data.prefix(2))
    }
    guard step == 1 else { return nil }
    step = 2
    defer { finished.signal() }
    return try await withTaskCancellationHandler {
      started.signal()
      if !released { await withCheckedContinuation { waiter = $0 } }
      try Task.checkCancellation()
      return Data(data.dropFirst(2))
    } onCancel: {
      cancelled.signal()
    }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

private func waitForVolumeReadEvent(_ event: TestEvent) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await event.wait() }
    group.addTask {
      try await Task.sleep(for: .seconds(5))
      throw RemoteError.posix(ETIMEDOUT)
    }
    defer { group.cancelAll() }
    _ = try await group.next()
  }
}

private actor VolumeProvider: RemoteFileProvider {
  nonisolated let capabilities: ProviderCapabilities
  var files: [RemotePath: Data] = [:]
  var modifiedDates: [RemotePath: Date] = [:]
  var folders: Set<RemotePath> = [try! RemotePath("/")]
  var events: [String] = []
  var writeFails = false
  var moveFails = false
  var disconnected = false
  var offline = false
  var loginExpired = false
  var rangeUnsupported = false
  var connects = 0
  var rejectsExisting: Bool
  var slowListing = false
  var listing: [RemoteItem]?
  var nextReadControl: VolumeReadControl?
  var nextReadContents: Data?
  var readChunkSize: Int?
  var activeLists = 0
  var peakLists = 0
  var caseInsensitive = false
  var changeAfterStat: (RemotePath, Data)?
  var corruptsNextUpload = false
  var moveFailuresLeft = 0

  init(capabilities: ProviderCapabilities = volumeFullAccess, rejectsExisting: Bool = false) {
    self.capabilities = capabilities
    self.rejectsExisting = rejectsExisting
  }
  func put(_ path: String, data: String) throws { files[try RemotePath(path)] = Data(data.utf8) }
  func put(_ path: String, bytes: Data) throws { files[try RemotePath(path)] = bytes }
  func content(_ path: String) throws -> Data? { files[try RemotePath(path)] }
  func recorded() -> [String] { events }
  func resetEvents() { events = [] }
  func failWrites(_ enabled: Bool) { writeFails = enabled }
  func failMoves(_ enabled: Bool) { moveFails = enabled }
  // 网络断开：请求失败，重连也失败，直到网络恢复
  func loseConnection() {
    disconnected = true
    offline = true
  }
  func restoreNetwork() { offline = false }
  func expireLogin() { loginExpired = true }
  func restoreLogin() { loginExpired = false }
  func refuseRanges() { rangeUnsupported = true }
  func connectCount() -> Int { connects }
  func delayListing() { slowListing = true }
  func setListing(_ items: [RemoteItem]) { listing = items }
  func holdNextRead(_ control: VolumeReadControl) { nextReadControl = control }
  func replaceNextRead(with data: Data) { nextReadContents = data }
  func splitReads(into bytes: Int) { readChunkSize = bytes }
  func maximumLists() -> Int { peakLists }
  // 像 OneDrive、Dropbox 那样不分大小写，返回远端实际的名字
  func ignoreCase() { caseInsensitive = true }
  // 下一次查这个文件之后它就变了（手机还在录、网盘在同步）
  func change(_ path: String, afterNextStatTo data: String) throws {
    changeAfterStat = (try RemotePath(path), Data(data.utf8))
  }
  func corruptNextUpload() { corruptsNextUpload = true }
  func failNextMoves(_ count: Int) { moveFailuresLeft = count }
  func actualPath(_ path: RemotePath) -> RemotePath {
    guard caseInsensitive, files[path] == nil, !folders.contains(path) else { return path }
    return (Array(files.keys) + Array(folders)).first {
      $0.value.caseInsensitiveCompare(path.value) == .orderedSame
    } ?? path
  }
  func connect() async throws {
    connects += 1
    if offline { throw URLError(.notConnectedToInternet) }
    if loginExpired { throw RemoteError.unauthorized }
    disconnected = false
  }
  func disconnect() async { disconnected = true }
  func spaceInfo() async throws -> SpaceInfo { SpaceInfo(total: 1000, used: 100) }

  func item(_ path: RemotePath) throws -> RemoteItem {
    let path = actualPath(path)
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
    let found = try item(path)
    if let (changed, data) = changeAfterStat, changed == path {
      changeAfterStat = nil
      files[path] = data
    }
    return found
  }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    try checkConnection()
    events.append("read:\(path):\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "all")")
    if range != nil, rangeUnsupported { throw RemoteError.unsupported }
    guard var data = files[path] else { throw RemoteError.posix(ENOENT) }
    if let control = nextReadControl {
      nextReadControl = nil
      return AsyncThrowingStream(unfolding: { try await control.next() })
    }
    if let replacement = nextReadContents {
      nextReadContents = nil
      data = replacement
    }
    let slice: Data
    if let range {
      let lower = min(data.count, Int(range.lowerBound))
      slice = data.subdata(in: lower..<min(data.count, Int(range.upperBound)))
    } else {
      slice = data
    }
    let chunkSize = readChunkSize
    return AsyncThrowingStream { continuation in
      if let chunkSize {
        for start in stride(from: 0, to: slice.count, by: chunkSize) {
          continuation.yield(slice.subdata(in: start..<min(start + chunkSize, slice.count)))
        }
      } else {
        continuation.yield(slice.prefix(2))
        if slice.count > 2 { continuation.yield(slice.dropFirst(2)) }
      }
      continuation.finish()
    }
  }
  func write(_ path: RemotePath, from localFile: URL) async throws {
    try checkConnection()
    events.append("upload:\(path)")
    if writeFails { throw RemoteError.posix(ENOSPC) }
    if rejectsExisting, files[path] != nil { throw RemoteError.posix(EEXIST) }
    files[path] = try Data(contentsOf: localFile)
    if corruptsNextUpload {
      corruptsNextUpload = false
      files[path] = files[path]?.prefix(1)
    }
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
    if moveFailuresLeft > 0 {
      moveFailuresLeft -= 1
      throw RemoteError.posix(EACCES)
    }
    guard actualPath(to) == from || (files[actualPath(to)] == nil && !folders.contains(actualPath(to)))
    else { throw RemoteError.posix(EEXIST) }
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
  let connectionID = UUID()
  let provider: VolumeProvider
  let backend: RemoteVolumeBackend
  private let make: @Sendable (String) -> RemoteVolumeBackend

  init(
    capabilities: ProviderCapabilities = volumeFullAccess, replacesExisting: Bool = true,
    root: URL? = nil, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024,
    kind: ConnectionKind = .androidUSB, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let root =
      root
      ?? FileManager.default.temporaryDirectory.appending(path: "RemoteVolume-" + UUID().uuidString)
    let provider = VolumeProvider(capabilities: capabilities, rejectsExisting: !replacesExisting)
    let connectionID = connectionID
    let pending = PendingUploads.file(
      dataDirectory: root.appending(path: "Group"), connectionID: connectionID)
    make = { target in
      RemoteVolumeBackend(
        provider: provider, connectionID: connectionID, kind: kind, cacheRoot: root,
        replacesExisting: replacesExisting, cacheLimit: cacheLimit, pendingUploadsFile: pending,
        uploadTarget: target, now: now)
    }
    self.root = root
    self.provider = provider
    backend = make("account-a")
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func path(_ value: String) throws -> RemotePath { try RemotePath(value) }
  // 同一连接重新挂载：新的 backend，沿用本地目录和远端
  func remount(target: String = "account-a") -> RemoteVolumeBackend { make(target) }
  var pendingUploads: [String] {
    PendingUploads.paths(dataDirectory: root.appending(path: "Group"), connectionID: connectionID)
  }
  var writes: [String] {
    let directory = root.appending(path: connectionID.uuidString).appending(path: "Writes")
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }
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
  let upload = try #require(events.firstIndex { $0.hasPrefix("upload:/.file.diskit-upload-") })
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
  await fixture.provider.resetEvents()
  await #expect(throws: RemoteError.posix(EACCES)) { try await fixture.backend.close(path) }
  let retained = try #require(await fixture.backend.pendingWriteFiles[path])
  #expect(try Data(contentsOf: retained) == Data("new".utf8))
  // 原文件已删、改名重试也失败：远端暂存不再隐藏，新内容在 Finder 里看得到
  let events = await fixture.provider.recorded()
  let moves = events.filter { $0.hasPrefix("move:") }
  #expect(moves.count == 2)
  let temporary = try fixture.path(String(moves[0].dropFirst("move:".count).prefix { $0 != ":" }))
  #expect(await fixture.backend.recoveryPaths.isEmpty)
  #expect(try await fixture.provider.content(temporary.value) == Data("new".utf8))
  #expect(
    Set(try await fixture.backend.list(fixture.path("/")).map(\.name))
      == ["file", temporary.basename])
  #expect(fixture.pendingUploads == ["/file"])
  await fixture.provider.failMoves(false)
  try await fixture.backend.close(path)
  #expect(try await fixture.provider.content("/file") == Data("new".utf8))
  #expect(fixture.pendingUploads.isEmpty)
}

@Test func remoteVolumeReplacementRetriesTheRenameOnceAfterDeletingTheOriginal() async throws {
  let fixture = VolumeFixture(replacesExisting: false)
  defer { fixture.clean() }
  try await fixture.provider.put("/file", data: "old")
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/file")
  try await fixture.backend.open(path, writable: true)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("new".utf8))
  await fixture.provider.failNextMoves(1)
  try await fixture.backend.close(path)
  #expect(try await fixture.provider.content("/file") == Data("new".utf8))
  #expect(try await fixture.backend.list(fixture.path("/")).map(\.name) == ["file"])
  #expect(await fixture.backend.recoveryPaths.isEmpty)
  #expect(fixture.writes.isEmpty)
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

@Test func remoteVolumeOpenedAttributesUseDeviceAndCloudTTLButStatAndOpenStayFresh() async throws {
  for (kind, ttl) in [(ConnectionKind.androidUSB, 5.0), (.aliyunDrive, 30.0)] {
    let clock = Mutex(Date(timeIntervalSince1970: 100))
    let fixture = VolumeFixture(kind: kind, now: { clock.withLock { $0 } })
    defer { fixture.clean() }
    let path = try fixture.path("/file")
    try await fixture.provider.put("/file", data: "old")
    _ = try await fixture.backend.connect()
    #expect(try await fixture.backend.attributes(path).size == 3)
    try await fixture.provider.put("/file", data: "unopened")
    #expect(try await fixture.backend.attributes(path).size == 8)
    #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 2)

    await fixture.provider.resetEvents()
    try await fixture.backend.open(path, writable: false)
    for _ in 0..<32 { #expect(try await fixture.backend.attributes(path).size == 8) }
    #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 1)
    try await fixture.provider.put("/file", data: "changed externally")
    clock.withLock { $0 += ttl - 1 }
    #expect(try await fixture.backend.attributes(path).size == 8)
    clock.withLock { $0 += 1 }
    #expect(try await fixture.backend.attributes(path).size == 18)
    #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 2)

    try await fixture.provider.put("/file", data: "strict stat")
    #expect(try await fixture.backend.stat(path).size == 11)
    #expect(try await fixture.backend.attributes(path).size == 11)
    try await fixture.provider.put("/file", data: "reopened")
    try await fixture.backend.open(path, writable: false)
    #expect(try await fixture.backend.attributes(path).size == 8)
    #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 4)
    try await fixture.backend.close(path)
    await fixture.backend.disconnect()
  }
}

@Test func remoteVolumeAttributeCacheEndsAtCloseAndDisconnectAndFollowsRename() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  let source = try fixture.path("/file")
  let renamed = try fixture.path("/renamed")
  try await fixture.provider.put("/file", data: "initial")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(source, writable: false)
  #expect(try await fixture.backend.attributes(source).size == 7)
  try await fixture.backend.close(source)
  try await fixture.provider.put("/file", data: "after close")
  #expect(try await fixture.backend.attributes(source).size == 11)
  try await fixture.provider.put("/file", data: "next")
  #expect(try await fixture.backend.attributes(source).size == 4)

  try await fixture.backend.open(source, writable: false)
  await fixture.backend.disconnect()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.attributes(source)
  }
  try await fixture.provider.put("/file", data: "reconnected")
  _ = try await fixture.backend.connect()
  #expect(try await fixture.backend.attributes(source).size == 11)
  try await fixture.provider.put("/file", data: "fresh")
  #expect(try await fixture.backend.attributes(source).size == 5)

  try await fixture.backend.open(source, writable: false)
  try await fixture.backend.move(source, to: renamed)
  await fixture.provider.resetEvents()
  #expect(try await fixture.backend.attributes(renamed).size == 5)
  for _ in 0..<8 { #expect(try await fixture.backend.attributes(renamed).size == 5) }
  #expect(await fixture.provider.recorded().filter { $0 == "stat:/renamed" }.count == 1)
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await fixture.backend.attributes(source)
  }
  try await fixture.backend.remove(renamed, recursive: false)
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await fixture.backend.attributes(renamed)
  }
  await fixture.backend.disconnect()
}

@Test func remoteVolumeExpiredOpenAttributesAlsoRefreshTheWholeFileReadCache() async throws {
  let clock = Mutex(Date(timeIntervalSince1970: 100))
  var capabilities = volumeFullAccess
  capabilities.supportsRangeRead = false
  let fixture = VolumeFixture(capabilities: capabilities, now: { clock.withLock { $0 } })
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "old")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: false)
  #expect(try await fixture.backend.read(path, offset: 0, length: 99) == Data("old".utf8))
  try await fixture.provider.put("/file", data: "new contents")
  clock.withLock { $0 += 5 }
  #expect(try await fixture.backend.attributes(path).size == 12)
  #expect(try await fixture.backend.read(path, offset: 0, length: 99) == Data("new contents".utf8))
  #expect(await fixture.provider.recorded().filter { $0 == "read:/file:all" }.count == 2)
  try await fixture.backend.close(path)
  await fixture.backend.disconnect()
}

@Test func remoteVolumeStagedAttributesStayCurrentAcrossWritesTruncationDatesAndFlush() async throws {
  let fixture = VolumeFixture()
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "old")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: false)
  #expect(try await fixture.backend.attributes(path).size == 3)
  try await fixture.provider.put("/file", data: "abcdefgh")
  try await fixture.backend.open(path, writable: true)
  #expect(try await fixture.backend.attributes(path).size == 8)
  await fixture.provider.resetEvents()

  _ = try await fixture.backend.write(path, offset: 8, data: Data("XYZ".utf8))
  #expect(try await fixture.backend.attributes(path).size == 11)
  try await fixture.backend.resize(path, size: 4)
  #expect(try await fixture.backend.attributes(path).size == 4)
  let modified = Date(timeIntervalSince1970: 1_234)
  try await fixture.backend.setModifiedDate(path, date: modified)
  #expect(try await fixture.backend.attributes(path).modified == modified)
  #expect(await fixture.provider.recorded().filter { $0.hasPrefix("stat:") }.isEmpty)
  try await fixture.backend.flush(path)
  #expect(try await fixture.provider.content("/file") == Data("abcd".utf8))
  #expect(try await fixture.backend.attributes(path).size == 4)
  #expect(try await fixture.backend.attributes(path).modified == modified)

  try await fixture.backend.close(path)
  try await fixture.provider.put("/file", data: "outside after close")
  #expect(try await fixture.backend.attributes(path).size == 19)
  await fixture.backend.disconnect()
}

@Test func remoteVolumeCachedAttributesCannotHideANameCollisionWhenFlushingNewContent() async throws {
  let fixture = VolumeFixture()
  defer { fixture.clean() }
  let path = try fixture.path("/new")
  _ = try await fixture.backend.connect()
  _ = try await fixture.backend.createFile(path)
  try await fixture.backend.open(path, writable: false)
  #expect(try await fixture.backend.attributes(path).size == 0)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("ours".utf8))
  #expect(try await fixture.backend.attributes(path).size == 4)
  try await fixture.provider.put("/new", data: "created by another client")
  await fixture.provider.resetEvents()

  await #expect(throws: RemoteError.posix(EEXIST)) { try await fixture.backend.flush(path) }
  #expect(try await fixture.provider.content("/new") == Data("created by another client".utf8))
  #expect(await fixture.provider.recorded().contains("stat:/new"))
  #expect(await fixture.provider.recorded().filter { $0.hasPrefix("upload:") }.isEmpty)
  let retained = try #require(await fixture.backend.pendingWriteFiles[path])
  #expect(try Data(contentsOf: retained) == Data("ours".utf8))
  await fixture.backend.disconnect()
}

@Test func remoteVolumeCancelledDownloadWaitsForCleanupBeforeReleasingTheVolumeAndQuota() async throws {
  var capabilities = volumeFullAccess
  capabilities.supportsRangeRead = false
  let fixture = VolumeFixture(capabilities: capabilities, cacheLimit: 4)
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "abcd")
  _ = try await fixture.backend.connect()
  let control = VolumeReadControl(data: Data("abcd".utf8))
  await fixture.provider.holdNextRead(control)
  let readFinished = TestEvent()
  let read = Task {
    defer { readFinished.signal() }
    return try await fixture.backend.read(path, offset: 0, length: 4)
  }
  do {
    try await waitForVolumeReadEvent(control.started)
    read.cancel()
    try await waitForVolumeReadEvent(control.cancelled)
    let queued = TestEvent()
    let listed = TestEvent()
    let next = Task {
      queued.signal()
      _ = try await fixture.backend.list(fixture.path("/"))
      listed.signal()
    }
    try await waitForVolumeReadEvent(queued)
    for _ in 0..<3 { await Task.yield() }
    #expect(!readFinished.isSignaled)
    #expect(!listed.isSignaled)
    #expect(await fixture.provider.recorded().filter { $0 == "list:/" }.isEmpty)
    await control.release()
    await #expect(throws: CancellationError.self) { _ = try await read.value }
    try await next.value
    #expect(control.finished.isSignaled)
    #expect(listed.isSignaled)
  } catch {
    read.cancel()
    await control.release()
    _ = try? await read.value
    throw error
  }
  let directory = RemoteReadCache.directory(root: fixture.root, connectionID: await fixture.backend.connectionID)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  #expect(try await fixture.backend.read(path, offset: 0, length: 4) == Data("abcd".utf8))
  await fixture.backend.disconnect()
}

@Test func remoteVolumeWrongDownloadSizeIsRetryableAndClearsPartialCache() async throws {
  for received in [Data("ab".utf8), Data("abcdef".utf8)] {
    var capabilities = volumeFullAccess
    capabilities.supportsRangeRead = false
    let fixture = VolumeFixture(capabilities: capabilities, cacheLimit: 4)
    defer { fixture.clean() }
    let path = try fixture.path("/file")
    try await fixture.provider.put("/file", data: "abcd")
    _ = try await fixture.backend.connect()
    await fixture.provider.replaceNextRead(with: received)
    // 大小对不上不算断线，Finder 重试就能读到
    await #expect(throws: RemoteError.posix(EAGAIN)) {
      _ = try await fixture.backend.read(path, offset: 0, length: 4)
    }
    let directory = RemoteReadCache.directory(root: fixture.root, connectionID: await fixture.backend.connectionID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(try await fixture.backend.read(path, offset: 0, length: 4) == Data("abcd".utf8))
    #expect(await fixture.provider.connectCount() == 1)
    await fixture.backend.disconnect()
  }
}

@Test func remoteVolumeFileGrowingDuringDownloadDropsCachedSizeForTheNextRead() async throws {
  var capabilities = volumeFullAccess
  capabilities.supportsRangeRead = false
  let fixture = VolumeFixture(capabilities: capabilities, kind: .aliyunDrive)
  defer { fixture.clean() }
  let path = try fixture.path("/video.mp4")
  try await fixture.provider.put("/video.mp4", data: "abcd")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: false)
  await fixture.provider.replaceNextRead(with: Data("abcdef".utf8))
  await #expect(throws: RemoteError.posix(EAGAIN)) {
    _ = try await fixture.backend.read(path, offset: 0, length: 6)
  }
  try await fixture.provider.put("/video.mp4", data: "abcdef")
  #expect(try await fixture.backend.attributes(path).size == 6)
  #expect(try await fixture.backend.read(path, offset: 0, length: 6) == Data("abcdef".utf8))
  #expect(await fixture.provider.connectCount() == 1)
  try await fixture.backend.close(path)
}

@Test func remoteVolumeSizeChangesWhileStagingOrMovingAreRetryableNotDisconnects() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "abcd")
  _ = try await fixture.backend.connect()
  await fixture.provider.replaceNextRead(with: Data("ab".utf8))
  await #expect(throws: RemoteError.posix(EAGAIN)) {
    try await fixture.backend.open(path, writable: true)
  }
  #expect(await fixture.backend.pendingWriteFiles.isEmpty)
  #expect(fixture.writes.isEmpty)

  try await fixture.provider.change("/file", afterNextStatTo: "abcdefgh")
  await #expect(throws: RemoteError.posix(EAGAIN)) {
    try await fixture.backend.move(path, to: fixture.path("/moved"))
  }
  #expect(try await fixture.provider.content("/file") == Data("abcdefgh".utf8))
  try await fixture.backend.move(path, to: fixture.path("/moved"))
  #expect(try await fixture.provider.content("/moved") == Data("abcdefgh".utf8))
  #expect(await fixture.provider.connectCount() == 1)
}

@Test func remoteVolumeUploadWithWrongSizeKeepsOriginalAndConnection() async throws {
  let fixture = VolumeFixture(replacesExisting: false)
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "old")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: true)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("newer".utf8))
  await fixture.provider.corruptNextUpload()
  await #expect(throws: RemoteError.posix(EIO)) { try await fixture.backend.close(path) }
  #expect(try await fixture.provider.content("/file") == Data("old".utf8))
  #expect(await fixture.backend.pendingWriteFiles[path] != nil)
  try await fixture.backend.close(path)
  #expect(try await fixture.provider.content("/file") == Data("newer".utf8))
  #expect(await fixture.provider.connectCount() == 1)
}

@Test func remoteVolumeChunkedDownloadPreservesMegabyteBoundariesAndTheFinalTail() async throws {
  let megabyte = 1024 * 1024
  let size = 2 * megabyte + 17
  let contents = Data((0..<size).map { UInt8(($0 * 31 + $0 / 257) % 251 + 1) })
  var capabilities = volumeFullAccess
  capabilities.supportsRangeRead = false
  let fixture = VolumeFixture(capabilities: capabilities, cacheLimit: Int64(size))
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", bytes: contents)
  await fixture.provider.splitReads(into: 64 * 1024)
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: false)

  #expect(try await fixture.backend.read(path, offset: 0, length: size) == contents)
  for window in [(megabyte - 11)..<(megabyte + 29), (2 * megabyte - 11)..<size] {
    #expect(try await fixture.backend.read(path, offset: Int64(window.lowerBound),
                                          length: window.count) == contents.subdata(in: window))
  }
  #expect(await fixture.provider.recorded().filter { $0 == "read:/file:all" }.count == 1)
  try await fixture.backend.close(path)
  await fixture.backend.disconnect()
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_000)
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Test func remoteVolumeReconnectsAfterNetworkDropWithoutHammering() async throws {
  let clock = TestClock()
  let fixture = VolumeFixture(kind: .quark, now: { clock.now() })
  defer { fixture.clean() }
  try await fixture.provider.put("/file", data: "abcd")
  _ = try await fixture.backend.connect()
  await fixture.provider.loseConnection()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  // 网络还没恢复：试一次重连，失败后 5 秒内不再试
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  await fixture.provider.restoreNetwork()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  #expect(await fixture.provider.connectCount() == 2)
  clock.advance(5)
  #expect(try await fixture.backend.list(fixture.path("/")).map(\.name) == ["file"])
  #expect(await fixture.provider.connectCount() == 3)
  await fixture.backend.disconnect()
}

@Test func remoteVolumeDoesNotReconnectAfterUnmount() async throws {
  let fixture = VolumeFixture(kind: .quark)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  await fixture.backend.disconnect()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  #expect(await fixture.provider.connectCount() == 1)
}

@Test func remoteVolumeReconnectReportsExpiredLogin() async throws {
  let fixture = VolumeFixture(kind: .quark)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  await fixture.provider.loseConnection()
  await #expect(throws: RemoteError.notConnected) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
  await fixture.provider.restoreNetwork()
  await fixture.provider.expireLogin()
  // 登录失效要原样报出来，App 才能提示重新登录
  await #expect(throws: RemoteError.unauthorized) {
    _ = try await fixture.backend.list(fixture.path("/"))
  }
}

@Test func remoteVolumeOpenedFileReadsReuseOpenAttributesUntilTheyExpire() async throws {
  let clock = TestClock()
  let fixture = VolumeFixture(kind: .aliyunDrive, now: { clock.now() })
  defer { fixture.clean() }
  let path = try fixture.path("/file")
  try await fixture.provider.put("/file", data: "abcdefgh")
  _ = try await fixture.backend.connect()
  try await fixture.backend.open(path, writable: false)
  for offset in 0..<8 {
    #expect(try await fixture.backend.read(path, offset: Int64(offset), length: 1).count == 1)
  }
  #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 1)
  try await fixture.provider.put("/file", data: "abcdefghij")
  clock.advance(30)
  #expect(try await fixture.backend.read(path, offset: 8, length: 2) == Data("ij".utf8))
  #expect(await fixture.provider.recorded().filter { $0 == "stat:/file" }.count == 2)
  try await fixture.backend.close(path)
}

@Test func remoteVolumeLookupMatchesDecomposedNamesFromFinder() throws {
  let names = ["caf\u{E9}", "\u{304C}\u{3063}\u{3053}\u{3046}", "\u{D55C}\u{AE00}", "plain"]
  let items = try names.map {
    RemoteItem(
      path: try RemotePath("/" + $0), name: $0, isDirectory: false, size: 0, modified: .distantPast)
  }
  for name in names {
    let decomposed = name.decomposedStringWithCanonicalMapping
    let found = RemoteVolumeBackend.entries(named: Data(decomposed.utf8), in: items)
    #expect(found.map(\.name) == [name])
  }
  // 远端同时有两种写法时按字节取那一个
  let both = items + [
    RemoteItem(
      path: try RemotePath("/cafe\u{301}"), name: "cafe\u{301}", isDirectory: false, size: 1,
      modified: .distantPast)
  ]
  #expect(
    RemoteVolumeBackend.entries(named: Data("cafe\u{301}".utf8), in: both).map(\.size) == [1])
  #expect(RemoteVolumeBackend.entries(named: Data("CAF\u{C9}".utf8), in: items).isEmpty)
}

@Test func remoteVolumeCaseOnlyRenameOnCaseInsensitiveServiceIsNotAConflict() async throws {
  let fixture = VolumeFixture(kind: .oneDrive)
  defer { fixture.clean() }
  await fixture.provider.ignoreCase()
  try await fixture.provider.put("/photo.JPG", data: "image")
  try await fixture.provider.put("/other.txt", data: "text")
  _ = try await fixture.backend.connect()
  try await fixture.backend.move(fixture.path("/photo.JPG"), to: fixture.path("/photo.jpg"))
  #expect(try await fixture.provider.content("/photo.jpg") == Data("image".utf8))
  #expect(try await fixture.provider.content("/photo.JPG") == nil)
  #expect(!(await fixture.provider.recorded().contains { $0.hasPrefix("remove:") }))
  // 换成别的文件占着这个名字，仍然算重名
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await fixture.backend.move(fixture.path("/other.txt"), to: fixture.path("/PHOTO.jpg"))
  }
}

@Test func remoteVolumeFailedUploadSurvivesUnmountAndUploadsOnNextMount() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/new.txt")
  _ = try await fixture.backend.createFile(path)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("hello".utf8))
  await fixture.provider.failWrites(true)
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.close(path) }
  #expect(fixture.pendingUploads == ["/new.txt"])
  // 卸载时还是传不上去
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.flushAll() }
  await fixture.backend.disconnect()
  #expect(fixture.writes.count == 2)

  // 挂载时连不上：清单不能被清掉
  await fixture.provider.loseConnection()
  let offline = fixture.remount()
  await #expect(throws: RemoteError.notConnected) { _ = try await offline.connect() }
  #expect(fixture.pendingUploads == ["/new.txt"])
  await fixture.provider.restoreNetwork()

  // 下次挂载仍然失败：内容和记录都留着
  let second = fixture.remount()
  _ = try await second.connect()
  #expect(try await second.list(fixture.path("/")).map(\.name) == ["new.txt"])
  await second.uploadPendingWrites()
  #expect(try await fixture.provider.content("/new.txt") == nil)
  #expect(fixture.writes.count == 2)
  #expect(fixture.pendingUploads == ["/new.txt"])
  await second.disconnect()

  // 再挂载、网络正常：传上去后清掉本地内容和清单
  await fixture.provider.failWrites(false)
  let third = fixture.remount()
  _ = try await third.connect()
  #expect(try await third.read(path, offset: 0, length: 5) == Data("hello".utf8))
  await third.uploadPendingWrites()
  #expect(try await fixture.provider.content("/new.txt") == Data("hello".utf8))
  #expect(fixture.writes.isEmpty)
  #expect(fixture.pendingUploads.isEmpty)
  #expect(await third.pendingWriteFiles.isEmpty)
  await third.disconnect()
}

@Test func remoteVolumeRecoveredUploadKeepsConflictRulesAndSkipsOpenFiles() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let fresh = try fixture.path("/fresh")
  let opened = try fixture.path("/opened")
  for path in [fresh, opened] {
    _ = try await fixture.backend.createFile(path)
    _ = try await fixture.backend.write(path, offset: 0, data: Data("ours".utf8))
  }
  await fixture.provider.failWrites(true)
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.flushAll() }
  await fixture.backend.disconnect()
  await fixture.provider.failWrites(false)
  try await fixture.provider.put("/fresh", data: "created elsewhere meanwhile")

  let second = fixture.remount()
  _ = try await second.connect()
  try await second.open(opened, writable: false)
  await second.uploadPendingWrites()
  #expect(try await fixture.provider.content("/fresh") == Data("created elsewhere meanwhile".utf8))
  #expect(try await fixture.provider.content("/opened") == nil)
  #expect(fixture.pendingUploads == ["/fresh", "/opened"])
  try await second.close(opened)
  #expect(try await fixture.provider.content("/opened") == Data("ours".utf8))
  #expect(fixture.pendingUploads == ["/fresh"])
  await second.disconnect()
}

@Test func remoteVolumeHalfWrittenContentIsNotUploadedAfterACrash() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let copying = try fixture.path("/copying")
  let edited = try fixture.path("/edited")
  _ = try await fixture.backend.createFile(copying)
  _ = try await fixture.backend.write(copying, offset: 0, data: Data("par".utf8))
  // 上传失败后又开始改，改到一半崩溃
  _ = try await fixture.backend.createFile(edited)
  _ = try await fixture.backend.write(edited, offset: 0, data: Data("v1".utf8))
  await fixture.provider.failWrites(true)
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.flush(edited) }
  _ = try await fixture.backend.write(edited, offset: 2, data: Data("-half".utf8))
  await fixture.provider.failWrites(false)
  #expect(fixture.pendingUploads.isEmpty)

  // 扩展进程没了：旧 backend 不再参与
  await fixture.provider.resetEvents()
  let second = fixture.remount()
  _ = try await second.connect()
  await second.uploadPendingWrites()
  #expect(try await second.list(fixture.path("/")).isEmpty)
  #expect(!(await fixture.provider.recorded().contains { $0.hasPrefix("upload:") }))
  #expect(try await fixture.provider.content("/copying") == nil)
  #expect(try await fixture.provider.content("/edited") == nil)
  #expect(fixture.writes.isEmpty)
  await second.disconnect()
}

@Test func remoteVolumeFallsBackToWholeFileWhenDeviceRefusesRanges() async throws {
  let fixture = VolumeFixture()
  defer { fixture.clean() }
  try await fixture.provider.put("/file", data: "abcdef")
  await fixture.provider.refuseRanges()
  _ = try await fixture.backend.connect()
  #expect(try await fixture.backend.read(fixture.path("/file"), offset: 2, length: 3) == Data("cde".utf8))
  #expect(await fixture.provider.recorded().contains("read:/file:all"))
  await fixture.backend.disconnect()
}

@Test func remoteVolumeClosedFileStaysUploadableWhenReconnectFindsExpiredLogin() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/new.txt")
  _ = try await fixture.backend.createFile(path)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("hello".utf8))
  // 写完后断网，关闭时重连发现登录已失效
  await fixture.provider.loseConnection()
  await #expect(throws: RemoteError.notConnected) { _ = try await fixture.backend.list(fixture.path("/")) }
  await fixture.provider.restoreNetwork()
  await fixture.provider.expireLogin()
  await #expect(throws: RemoteError.unauthorized) { try await fixture.backend.close(path) }
  await fixture.backend.disconnect()

  // 重新登录后挂载：内容已记成写完，会接着传，不会被当成写到一半丢掉
  await fixture.provider.restoreLogin()
  let next = fixture.remount()
  _ = try await next.connect()
  await next.uploadPendingWrites()
  #expect(try await fixture.provider.content("/new.txt") == Data("hello".utf8))
  await next.disconnect()
}

@Test func remoteVolumePendingWritesNeverGoToAnotherAccount() async throws {
  let fixture = VolumeFixture(kind: .aliyunDrive)
  defer { fixture.clean() }
  _ = try await fixture.backend.connect()
  let path = try fixture.path("/new.txt")
  _ = try await fixture.backend.createFile(path)
  _ = try await fixture.backend.write(path, offset: 0, data: Data("hello".utf8))
  await fixture.provider.failWrites(true)
  await #expect(throws: RemoteError.posix(ENOSPC)) { try await fixture.backend.close(path) }
  await fixture.backend.disconnect()
  await fixture.provider.failWrites(false)

  // 位置改成了别的账号：不传过去，本地内容留着
  let other = fixture.remount(target: "account-b")
  _ = try await other.connect()
  await other.uploadPendingWrites()
  #expect(try await fixture.provider.content("/new.txt") == nil)
  #expect(fixture.writes.count == 2)
  await other.disconnect()

  // 换回原来的账号后照常补传
  let original = fixture.remount()
  _ = try await original.connect()
  await original.uploadPendingWrites()
  #expect(try await fixture.provider.content("/new.txt") == Data("hello".utf8))
  await original.disconnect()
}

@Test func uploadTargetIgnoresCosmeticParameters() {
  var connection = Connection(kind: .quark, name: "夸克")
  connection.params = ["userID": "1", "nickname": "a"]
  let target = connection.uploadTarget
  connection.params["nickname"] = "b"
  connection.params["avatarURL"] = "https://x"
  connection.name = "改名"
  #expect(connection.uploadTarget == target)
  connection.params["userID"] = "2"
  #expect(connection.uploadTarget != target)
}
