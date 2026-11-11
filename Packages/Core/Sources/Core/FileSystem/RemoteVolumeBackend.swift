import Foundation
import OSLog

public actor RemoteVolumeBackend {
  public nonisolated let provider: any RemoteFileProvider
  public nonisolated var capabilities: ProviderCapabilities { provider.capabilities }

  struct DirectoryEntry {
    let items: [RemoteItem]
    let expires: Date
  }
  struct StagedFile {
    let url: URL
    var item: RemoteItem
    var dirty: Bool
    var existedRemotely: Bool
    var retainedForRecovery = false
  }
  struct CachedFile {
    let url: URL
    let item: RemoteItem
  }

  let connectionID: UUID
  let cacheRoot: URL
  let cacheLimit: Int64
  let replacesExisting: Bool
  let directoryTTL: TimeInterval
  let now: @Sendable () -> Date
  let logger = Logger(subsystem: "com.seaony.Kayoi.FS", category: "remote-volume")
  var connected = false
  var directories: [RemotePath: DirectoryEntry] = [:]
  var staged: [RemotePath: StagedFile] = [:]
  var wholeFiles: [RemotePath: CachedFile] = [:]
  var hiddenUploads: Set<RemotePath> = []
  private var running = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(
    provider: any RemoteFileProvider, connectionID: UUID, kind: ConnectionKind,
    cacheRoot: URL, replacesExisting: Bool, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024
  ) {
    self.provider = provider
    self.connectionID = connectionID
    self.cacheRoot = cacheRoot
    self.replacesExisting = replacesExisting
    self.cacheLimit = cacheLimit
    directoryTTL = Self.ttl(kind)
    now = { Date() }
  }

  init(
    provider: any RemoteFileProvider, connectionID: UUID, kind: ConnectionKind,
    cacheRoot: URL, replacesExisting: Bool, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024,
    now: @escaping @Sendable () -> Date
  ) {
    self.provider = provider
    self.connectionID = connectionID
    self.cacheRoot = cacheRoot
    self.replacesExisting = replacesExisting
    self.cacheLimit = cacheLimit
    directoryTTL = Self.ttl(kind)
    self.now = now
  }

  static func ttl(_ kind: ConnectionKind) -> TimeInterval {
    switch kind {
    case .androidUSB, .androidWiFi, .ricohGR, .cameraUSB: 5
    default: 30
    }
  }

  public var pendingWriteFiles: [RemotePath: URL] { staged.mapValues(\.url) }
  public var recoveryPaths: [RemotePath] { Array(hiddenUploads) }

  // actor 在等待远端时会重入；这道门保证同一卷只有一项远端操作。
  func perform<Value: Sendable>(
    _ operation: String, path: RemotePath? = nil,
    _ body: (isolated RemoteVolumeBackend) async throws -> Value
  ) async throws -> Value {
    await acquire()
    defer { release() }
    do {
      try Task.checkCancellation()
      logger.debug(
        "连接 \(self.connectionID.uuidString, privacy: .public) 开始 \(operation, privacy: .public) \(path?.value ?? "/", privacy: .private)"
      )
      let result = try await body(self)
      logger.debug(
        "连接 \(self.connectionID.uuidString, privacy: .public) 完成 \(operation, privacy: .public)")
      return result
    } catch {
      let value = error as NSError
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) \(operation, privacy: .public) \(path?.value ?? "/", privacy: .private)：\(value.domain, privacy: .public) code=\(value.code) \(value.localizedDescription, privacy: .private)"
      )
      if let path, let stage = staged[path] {
        logger.error("未完成操作的本地内容保留于 \(stage.url.path, privacy: .public)")
      }
      if Self.isDisconnect(error) {
        connected = false
        await provider.disconnect()
        throw RemoteError.notConnected
      }
      throw error
    }
  }

  private func acquire() async {
    if running {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      running = true
    }
  }

  private func release() {
    if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
  }

  static func isDisconnect(_ error: Error) -> Bool {
    if NetworkFailure.isTransportError(error) { return true }
    if let error = error as? RemoteError, error == .notConnected || error == .protocolError {
      return true
    }
    let value = error as NSError
    return value.domain == NSPOSIXErrorDomain
      && [
        ENODEV, ENXIO, ENOTCONN, ECONNRESET, ECONNREFUSED, EPIPE, ENETDOWN, ENETUNREACH,
        EHOSTUNREACH, ETIMEDOUT,
      ].contains(Int32(value.code))
  }

  func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  public func connect() async throws -> SpaceInfo {
    try await perform("connect") { backend in
      do {
        try await backend.provider.connect()
        let space: SpaceInfo
        do { space = try await backend.provider.spaceInfo() } catch RemoteError.unsupported {
          space = SpaceInfo(total: nil, used: nil)
        }
        backend.connected = true
        backend.logger.info("连接 \(backend.connectionID.uuidString, privacy: .public) 已连接")
        return space
      } catch {
        backend.connected = false
        await backend.provider.disconnect()
        throw error
      }
    }
  }

  public func disconnect() async {
    await acquire()
    defer { release() }
    connected = false
    directories.removeAll()
    await provider.disconnect()
    logger.info(
      "连接 \(self.connectionID.uuidString, privacy: .public) 已断开，保留写入暂存文件 \(self.staged.count)")
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try await perform("list", path: path) { backend in
      try backend.requireConnection()
      let items: [RemoteItem]
      if let cached = backend.directories[path], cached.expires > backend.now() {
        items = cached.items
      } else {
        items = try await backend.provider.list(path)
        backend.directories[path] = DirectoryEntry(
          items: items, expires: backend.now().addingTimeInterval(backend.directoryTTL))
      }
      var merged: [RemotePath: RemoteItem] = [:]
      for item in items
      where item.path.basename != "." && item.path.basename != ".."
        && !backend.hiddenUploads.contains(item.path)
      {
        guard merged[item.path] == nil else { throw RemoteError.posix(EEXIST) }
        merged[item.path] = item
      }
      for (key, stage) in backend.staged where key.parent == path { merged[key] = stage.item }
      return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("stat", path: path) { try await $0.statUnlocked(path) }
  }

  func statUnlocked(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if let stage = staged[path] { return stage.item }
    guard !hiddenUploads.contains(path) else { throw RemoteError.posix(ENOENT) }
    let item = try await provider.stat(path)
    if let cached = wholeFiles[path], cached.item != item { wholeFiles.removeValue(forKey: path) }
    return item
  }

  func remoteItem(_ path: RemotePath) async throws -> RemoteItem? {
    do { return try await provider.stat(path) } catch {
      let value = error as NSError
      if value.domain == NSPOSIXErrorDomain, value.code == Int(ENOENT) { return nil }
      throw error
    }
  }

  public func createFile(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("create", path: path) { backend in
      try backend.requireConnection()
      guard backend.capabilities.canWrite else { throw RemoteError.posix(EROFS) }
      guard backend.staged[path] == nil, try await backend.remoteItem(path) == nil else {
        throw RemoteError.posix(EEXIST)
      }
      let item = RemoteItem(
        path: path, name: path.basename, isDirectory: false, size: 0, modified: backend.now())
      let file = try backend.temporaryWriteFile()
      backend.staged[path] = StagedFile(url: file, item: item, dirty: true, existedRemotely: false)
      await backend.invalidate([path])
      return item
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("mkdir", path: path) { backend in
      try backend.requireConnection()
      guard backend.capabilities.canWrite else { throw RemoteError.posix(EROFS) }
      try await backend.provider.makeDirectory(path)
      await backend.invalidate([path])
      return try await backend.provider.stat(path)
    }
  }

  public func open(_ path: RemotePath, writable: Bool) async throws {
    try await perform("open", path: path) { backend in
      try backend.requireConnection()
      if writable {
        try await backend.prepareStage(path)
      } else {
        _ = try await backend.statUnlocked(path)
      }
    }
  }

  public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
    try await perform("read", path: path) { backend in
      try backend.requireConnection()
      guard offset >= 0, length >= 0, !offset.addingReportingOverflow(Int64(length)).overflow else {
        throw RemoteError.invalidPath
      }
      guard length > 0 else { return Data() }
      if let stage = backend.staged[path] {
        return try backend.readLocal(stage.url, offset: offset, length: length)
      }
      if backend.capabilities.supportsRangeRead {
        let item = try await backend.statUnlocked(path)
        guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
        guard offset < item.size else { return Data() }
        let stream = try await backend.provider.read(
          path, range: offset..<min(item.size, offset + Int64(length)))
        var result = Data()
        for try await chunk in stream {
          try Task.checkCancellation()
          result.append(chunk.prefix(length - result.count))
          if result.count == length { break }
        }
        return result
      }
      return try await backend.readWholeFile(path, offset: offset, length: length)
    }
  }

  func readLocal(_ file: URL, offset: Int64, length: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: length) ?? Data()
  }

  func readWholeFile(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
    let cached: CachedFile
    if let current = wholeFiles[path] {
      cached = current
    } else {
      let item = try await statUnlocked(path)
      guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
      cached = CachedFile(
        url: RemoteReadCache.file(root: cacheRoot, connectionID: connectionID, item: item),
        item: item)
      wholeFiles[path] = cached
    }
    if let data = try await RemoteReadCache.shared.read(
      cached.url, expectedSize: cached.item.size, offset: offset, length: length)
    {
      return data
    }
    guard cached.item.size <= cacheLimit else { throw RemoteError.posix(EFBIG) }
    let manager = FileManager.default
    try manager.createDirectory(
      at: cached.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = cached.url.deletingLastPathComponent().appending(
      path: ".download-" + UUID().uuidString)
    defer { try? manager.removeItem(at: temporary) }
    let reservation = UUID()
    try await RemoteReadCache.shared.reserve(
      root: cacheRoot, bytes: cached.item.size, limit: cacheLimit, id: reservation)
    do {
      let size = try await download(path, to: temporary, maximumSize: cached.item.size)
      guard size == cached.item.size else { throw RemoteError.protocolError }
      try await RemoteReadCache.shared.install(
        temporary, as: cached.url, root: cacheRoot, limit: cacheLimit, reservation: reservation)
    } catch {
      await RemoteReadCache.shared.cancel(root: cacheRoot, id: reservation)
      throw error
    }
    guard
      let data = try await RemoteReadCache.shared.read(
        cached.url, expectedSize: cached.item.size, offset: offset, length: length)
    else { throw RemoteError.posix(EIO) }
    return data
  }

  func download(_ path: RemotePath, to file: URL, maximumSize: Int64? = nil) async throws -> Int64 {
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var size: Int64 = 0
    for try await chunk in try await provider.read(path, range: nil) {
      try Task.checkCancellation()
      if let maximumSize, Int64(chunk.count) > maximumSize - size {
        throw RemoteError.protocolError
      }
      try handle.write(contentsOf: chunk)
      size += Int64(chunk.count)
    }
    return size
  }

  func invalidate(_ paths: [RemotePath]) async {
    for path in paths {
      directories.removeValue(forKey: path.parent)
      for key in Array(directories.keys) where Self.contains(path, key) {
        directories.removeValue(forKey: key)
      }
    }
    let cached = wholeFiles.keys.filter { key in paths.contains { Self.contains($0, key) } }
    for key in cached { wholeFiles.removeValue(forKey: key) }
    do {
      try await RemoteReadCache.shared.invalidate(
        root: cacheRoot, connectionID: connectionID, paths: paths + cached)
    } catch {
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) 清理旧读缓存失败：\(error.localizedDescription, privacy: .private)"
      )
    }
  }

  static func contains(_ parent: RemotePath, _ child: RemotePath) -> Bool {
    parent == child || child.value.hasPrefix(parent.value == "/" ? "/" : parent.value + "/")
  }
}
