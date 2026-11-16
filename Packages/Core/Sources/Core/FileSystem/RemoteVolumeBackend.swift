import Foundation
import OSLog

public actor RemoteVolumeBackend {
  public nonisolated let provider: any RemoteFileProvider
  public nonisolated let overlay: LocalMetadataOverlay
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
    var journal: WriteJournal.State?
  }
  struct CachedFile {
    let url: URL
    let item: RemoteItem
  }
  struct AttributeEntry {
    let item: RemoteItem
    let expires: Date
  }

  let connectionID: UUID
  let cacheRoot: URL
  let cacheLimit: Int64
  let replacesExisting: Bool
  let uploadTarget: String
  let directoryTTL: TimeInterval
  let pendingUploadsFile: URL?
  let now: @Sendable () -> Date
  let logger = Logger(subsystem: "com.seaony.Diskit.FS", category: "remote-volume")
  var connected = false
  // 挂载时连上过、还没卸载：中途断开后由下一次操作自动重连
  var reconnects = false
  var lastReconnect: Date?
  // 最近一次自动重连失败的原因（如登录失效）；真正要连远端时才报出来，
  // 让关闭文件等操作先把本地该记的记好
  var reconnectFailure: Error?
  var directories: [RemotePath: DirectoryEntry] = [:]
  var staged: [RemotePath: StagedFile] = [:]
  var wholeFiles: [RemotePath: CachedFile] = [:]
  var openedPaths: Set<RemotePath> = []
  var attributesByPath: [RemotePath: AttributeEntry] = [:]
  var hiddenUploads: Set<RemotePath> = []
  var reportedPendingUploads: [String]?
  // 接管过上次留下的记录后才更新清单，连不上时不能把上次的清单清掉
  var journalsAdopted = false
  private var running = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  // pendingUploadsFile：没传上去的文件清单写到这里给 App 看，见 PendingUploads
  public init(
    provider: any RemoteFileProvider, connectionID: UUID, kind: ConnectionKind,
    cacheRoot: URL, replacesExisting: Bool, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024,
    pendingUploadsFile: URL? = nil, uploadTarget: String = ""
  ) {
    self.init(
      provider: provider, connectionID: connectionID, kind: kind, cacheRoot: cacheRoot,
      replacesExisting: replacesExisting, cacheLimit: cacheLimit,
      pendingUploadsFile: pendingUploadsFile, uploadTarget: uploadTarget, now: { Date() })
  }

  init(
    provider: any RemoteFileProvider, connectionID: UUID, kind: ConnectionKind,
    cacheRoot: URL, replacesExisting: Bool, cacheLimit: Int64 = 5 * 1024 * 1024 * 1024,
    pendingUploadsFile: URL? = nil, uploadTarget: String = "", now: @escaping @Sendable () -> Date
  ) {
    self.provider = provider
    overlay = LocalMetadataOverlay(cacheRoot: cacheRoot, connectionID: connectionID)
    self.connectionID = connectionID
    self.cacheRoot = cacheRoot
    self.replacesExisting = replacesExisting
    self.cacheLimit = cacheLimit
    self.pendingUploadsFile = pendingUploadsFile
    self.uploadTarget = uploadTarget
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
    defer {
      reportPendingUploads()
      release()
    }
    do {
      try Task.checkCancellation()
      await reconnectIfNeeded()
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
        openedPaths.removeAll()
        attributesByPath.removeAll()
        await provider.disconnect()
        throw RemoteError.notConnected
      }
      throw error
    }
  }

  // 网络抖一下、请求超时都会断开；不重连的话整个卷要推出重挂才能再用。
  // 重连失败后 5 秒内不再试，免得 Finder 连续访问时反复请求。
  private func reconnectIfNeeded() async {
    guard !connected, reconnects else { return }
    if let lastReconnect, now().timeIntervalSince(lastReconnect) < 5 { return }
    lastReconnect = now()
    do {
      try await provider.connect()
      connected = true
      reconnectFailure = nil
      logger.info("连接 \(self.connectionID.uuidString, privacy: .public) 已自动重连")
    } catch {
      // 连接本身可能卡到超时才失败，从失败时刻重新计时
      lastReconnect = now()
      // 网络类失败照常报“已断开”；登录失效等其他原因原样交给 Finder 和 App
      reconnectFailure = Self.isDisconnect(error) ? nil : error
      let value = error as NSError
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) 自动重连失败：\(value.domain, privacy: .public) code=\(value.code)")
      await provider.disconnect()
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

  // 远端文件在读的过程中变了大小（手机正在录像、网盘正在同步）。这不是断线，
  // 调用方清掉这个文件的缓存，让 Finder 重试时拿到新大小
  static let sizeChanged = RemoteError.posix(EAGAIN)

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
    guard connected else { throw reconnectFailure ?? RemoteError.notConnected }
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
        backend.reconnects = true
        backend.reconnectFailure = nil
        backend.logger.info("连接 \(backend.connectionID.uuidString, privacy: .public) 已连接")
        backend.adoptJournaledWrites()
        return space
      } catch {
        backend.connected = false
        backend.reconnects = false
        backend.openedPaths.removeAll()
        backend.attributesByPath.removeAll()
        await backend.provider.disconnect()
        throw error
      }
    }
  }

  public func disconnect() async {
    await acquire()
    defer { release() }
    connected = false
    reconnects = false
    reconnectFailure = nil
    directories.removeAll()
    openedPaths.removeAll()
    attributesByPath.removeAll()
    await provider.disconnect()
    logger.info(
      "连接 \(self.connectionID.uuidString, privacy: .public) 已断开，保留写入暂存文件 \(self.staged.count)")
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try await perform("list", path: path) { backend in
      if LocalMetadataOverlay.handles(path) { return try backend.overlay.list(path) }
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
        && !LocalMetadataOverlay.handles(item.path)
      {
        guard merged[item.path] == nil else { throw RemoteError.posix(EEXIST) }
        merged[item.path] = item
      }
      for item in try backend.overlay.list(path) { merged[item.path] = item }
      for (key, stage) in backend.staged where key.parent == path { merged[key] = stage.item }
      return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("stat", path: path) { try await $0.statUnlocked(path) }
  }

  public func attributes(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("attributes", path: path) { backend in
      if LocalMetadataOverlay.handles(path) { return try backend.overlay.stat(path) }
      try backend.requireConnection()
      if let stage = backend.staged[path] { return stage.item }
      return try await backend.openedItem(path)
    }
  }

  // 打开着的文件在有效期内直接用记下的属性；Finder 每读 1 MiB 都会问一次大小，不能每次都请求远端
  func openedItem(_ path: RemotePath) async throws -> RemoteItem {
    if openedPaths.contains(path), let entry = attributesByPath[path], entry.expires > now() {
      return entry.item
    }
    return try await statUnlocked(path)
  }

  func statUnlocked(_ path: RemotePath) async throws -> RemoteItem {
    if LocalMetadataOverlay.handles(path) { return try overlay.stat(path) }
    try requireConnection()
    if let stage = staged[path] { return stage.item }
    guard !hiddenUploads.contains(path) else { throw RemoteError.posix(ENOENT) }
    let item = try await provider.stat(path)
    if let cached = wholeFiles[path], cached.item != item { wholeFiles.removeValue(forKey: path) }
    if openedPaths.contains(path) {
      attributesByPath[path] = AttributeEntry(
        item: item, expires: now().addingTimeInterval(directoryTTL))
    }
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
      if LocalMetadataOverlay.handles(path) { return try backend.overlay.createFile(path) }
      try backend.requireConnection()
      guard backend.capabilities.canWrite else { throw RemoteError.posix(EROFS) }
      guard backend.staged[path] == nil, try await backend.remoteItem(path) == nil else {
        throw RemoteError.posix(EEXIST)
      }
      let item = RemoteItem(
        path: path, name: path.basename, isDirectory: false, size: 0, modified: backend.now())
      let file = try backend.temporaryWriteFile()
      backend.staged[path] = StagedFile(url: file, item: item, dirty: true, existedRemotely: false)
      try backend.recordJournal(path, .writing)
      await backend.invalidate([path])
      return item
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws -> RemoteItem {
    try await perform("mkdir", path: path) { backend in
      if LocalMetadataOverlay.handles(path) { return try backend.overlay.makeDirectory(path) }
      try backend.requireConnection()
      guard backend.capabilities.canWrite else { throw RemoteError.posix(EROFS) }
      try await backend.provider.makeDirectory(path)
      await backend.invalidate([path])
      return try await backend.provider.stat(path)
    }
  }

  public func open(_ path: RemotePath, writable: Bool) async throws {
    try await perform("open", path: path) { backend in
      if LocalMetadataOverlay.handles(path) {
        let item = try backend.overlay.stat(path)
        if writable && item.isDirectory { throw RemoteError.posix(EISDIR) }
        return
      }
      try backend.requireConnection()
      let item = try await backend.statUnlocked(path)
      if writable {
        try await backend.prepareStage(path)
      }
      if !item.isDirectory {
        backend.openedPaths.insert(path)
        backend.attributesByPath[path] = AttributeEntry(
          item: backend.staged[path]?.item ?? item,
          expires: backend.now().addingTimeInterval(backend.directoryTTL))
      }
    }
  }

  public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
    try await perform("read", path: path) { backend in
      guard offset >= 0, length >= 0, !offset.addingReportingOverflow(Int64(length)).overflow else {
        throw RemoteError.invalidPath
      }
      if LocalMetadataOverlay.handles(path) {
        return try backend.overlay.read(path, offset: offset, length: length)
      }
      try backend.requireConnection()
      guard length > 0 else { return Data() }
      if let stage = backend.staged[path] {
        return try backend.readLocal(stage.url, offset: offset, length: length)
      }
      if backend.capabilities.supportsRangeRead {
        let item = try await backend.openedItem(path)
        guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
        guard offset < item.size else { return Data() }
        let stream: AsyncThrowingStream<Data, Error>
        do {
          stream = try await backend.provider.read(
            path, range: offset..<min(item.size, offset + Int64(length)))
        } catch RemoteError.unsupported {
          // 个别设备读不了指定范围（如很旧的安卓手机），退回整个文件下载
          return try await backend.readWholeFile(path, offset: offset, length: length)
        }
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
    let started = ContinuousClock.now
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
    let preflightSeconds = Self.seconds(since: started)
    var reserveSeconds = 0.0
    var streamSetupSeconds = 0.0
    var transferSeconds = 0.0
    var writeSeconds = 0.0
    var writeCalls = 0
    var installSeconds = 0.0
    var firstReadSeconds = 0.0
    var downloadedBytes: Int64 = 0
    var completed = false
    defer {
      logger.info(
        "整文件缓存汇总 connection=\(self.connectionID.uuidString, privacy: .public) path=\(path.value, privacy: .private) bytes=\(downloadedBytes) preflight_s=\(preflightSeconds) reserve_s=\(reserveSeconds) stream_setup_s=\(streamSetupSeconds) transfer_including_write_s=\(transferSeconds) local_write_s=\(writeSeconds) local_write_calls=\(writeCalls) install_s=\(installSeconds) first_read_s=\(firstReadSeconds) total_s=\(Self.seconds(since: started)) success=\(completed)"
      )
    }
    guard cached.item.size <= cacheLimit else { throw RemoteError.posix(EFBIG) }
    let manager = FileManager.default
    try manager.createDirectory(
      at: cached.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = cached.url.deletingLastPathComponent().appending(
      path: ".download-" + UUID().uuidString)
    defer { try? manager.removeItem(at: temporary) }
    let reservation = UUID()
    let reserveStarted = ContinuousClock.now
    try await RemoteReadCache.shared.reserve(
      root: cacheRoot, bytes: cached.item.size, limit: cacheLimit, id: reservation)
    reserveSeconds = Self.seconds(since: reserveStarted)
    do {
      let size = try await download(path, to: temporary, maximumSize: cached.item.size) {
        streamSetupSeconds = $0
        transferSeconds = $1
        writeSeconds = $2
        downloadedBytes = $3
        writeCalls = $4
      }
      downloadedBytes = size
      guard size == cached.item.size else { throw Self.sizeChanged }
      let installStarted = ContinuousClock.now
      try await RemoteReadCache.shared.install(
        temporary, as: cached.url, root: cacheRoot, limit: cacheLimit, reservation: reservation)
      installSeconds = Self.seconds(since: installStarted)
    } catch {
      await RemoteReadCache.shared.cancel(root: cacheRoot, id: reservation)
      if (error as? RemoteError) == Self.sizeChanged { await invalidate([path]) }
      throw error
    }
    let firstReadStarted = ContinuousClock.now
    guard
      let data = try await RemoteReadCache.shared.read(
        cached.url, expectedSize: cached.item.size, offset: offset, length: length)
    else { throw RemoteError.posix(EIO) }
    firstReadSeconds = Self.seconds(since: firstReadStarted)
    completed = true
    return data
  }

  private static func seconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
  }

  func download(
    _ path: RemotePath, to file: URL, maximumSize: Int64? = nil,
    timing: ((Double, Double, Double, Int64, Int) -> Void)? = nil
  ) async throws -> Int64 {
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var size: Int64 = 0
    let setupStarted = ContinuousClock.now
    var transferStarted: ContinuousClock.Instant?
    var setupSeconds = 0.0
    var writeSeconds = 0.0
    var writeCalls = 0
    defer {
      timing?(
        transferStarted == nil ? Self.seconds(since: setupStarted) : setupSeconds,
        transferStarted.map { Self.seconds(since: $0) } ?? 0, writeSeconds, size,
        writeCalls)
    }
    let stream = try await provider.read(path, range: nil)
    setupSeconds = Self.seconds(since: setupStarted)
    transferStarted = .now
    // 小块攒到 1MiB 再落盘，减少写入系统调用；不按整文件预留内存。
    let writeSize = 1024 * 1024
    var pending = Data()
    pending.reserveCapacity(writeSize)
    func write(_ data: Data) throws {
      try Task.checkCancellation()
      let writeStarted = timing == nil ? nil : ContinuousClock.now
      defer {
        if let writeStarted { writeSeconds += Self.seconds(since: writeStarted) }
      }
      writeCalls += 1
      try handle.write(contentsOf: data)
    }
    func flushPending() throws {
      guard !pending.isEmpty else { return }
      try write(pending)
      pending.removeAll(keepingCapacity: true)
    }
    for try await chunk in stream {
      try Task.checkCancellation()
      if let maximumSize, Int64(chunk.count) > maximumSize - size { throw Self.sizeChanged }
      size += Int64(chunk.count)
      if chunk.count >= writeSize {
        try flushPending()
        try write(chunk)
      } else {
        let available = writeSize - pending.count
        if chunk.count > available {
          pending.append(chunk.prefix(available))
          try flushPending()
          pending.append(chunk.suffix(chunk.count - available))
        } else {
          pending.append(chunk)
        }
        if pending.count == writeSize { try flushPending() }
      }
    }
    try Task.checkCancellation()
    try flushPending()
    return size
  }

  func invalidate(_ paths: [RemotePath]) async {
    for path in paths {
      directories.removeValue(forKey: path.parent)
      for key in Array(attributesByPath.keys) where key == path.parent || Self.contains(path, key) {
        attributesByPath.removeValue(forKey: key)
      }
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
