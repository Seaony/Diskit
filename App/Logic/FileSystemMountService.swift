import Core
import Darwin
import Foundation
import OSLog

enum FileSystemMountError: Error, LocalizedError {
  case disabled, unavailable, unsavedConnection, commandFailed(Int32), conflictingExtension

  var errorDescription: String? {
    switch self {
    case .disabled: L("请先在系统设置中启用 Diskit 文件系统扩展。")
    case .conflictingExtension: L("系统里还登记着另一份 Diskit。请退出其他位置打开的 Diskit，然后重试。")
    case .unavailable: L("此版本无法使用文件系统扩展，请重新构建并签名 Diskit。")
    case .unsavedConnection: L("请先保存这个位置，再验证挂载。")
    case .commandFailed(let code): LF("挂载命令失败（退出码 %@），请查看 Diskit 日志。", String(code))
    }
  }

  // launchd 165：同一个扩展 ID 之前从另一份 Diskit（开发版、DMG 里直接打开的）启动过。
  static func isConflictingExtension(_ error: Error) -> Bool {
    if case .conflictingExtension? = error as? FileSystemMountError { return true }
    return ErrorDiagnostics.chain(error).contains { $0.domain == "OSLaunchdErrorDomain" && $0.code == 165 }
  }

  // mount 命令只给出文字：同样的冲突显示为 extensionKit 错误 2，文字随系统语言变，只认错误域和编号
  nonisolated static func isConflictingExtension(commandOutput: String) -> Bool {
    commandOutput.range(of: #"com\.apple\.extensionKit\.errorDomain\D{0,8}2(?!\d)"#, options: .regularExpression) != nil
  }
}

@MainActor final class FileSystemMountService: SMBServing {
  struct MountEntry: Sendable {
    let type: String
    let source: String
    let path: URL
    let filesystemID: Data
    var availableBytes: Int64?

    func matches(_ connection: Connection) -> Bool {
      guard type == "diskit", let url = URL(string: source) else { return false }
      return (try? FileSystemAddress.connection(for: url, in: [connection])) != nil
    }

    var isDiskitVolume: Bool {
      guard type == "diskit", let url = URL(string: source),
        let host = url.host, let id = UUID(uuidString: host)
      else { return false }
      let candidates = ConnectionKind.allCases.filter { $0.fileSystemScheme == url.scheme?.lowercased() }
        .map { Connection(id: id, kind: $0) }
      return (try? FileSystemAddress.connection(for: url, in: candidates)) != nil
    }
  }

  struct Operations {
    var sharedStorageAvailable: @MainActor () -> Bool = { RuntimeStorage.current.usesSharedStorage }
    var usesClient: @MainActor () -> Bool = { if #available(macOS 27, *) { true } else { false } }
    var enabled: @MainActor (@escaping FileSystemCompletion<Bool?>) -> Void = NativeFileSystemMount.enabled
    var mountClient: @MainActor (URL, @escaping FileSystemCompletion<URL>) throws -> Void = NativeFileSystemMount.mountClient
    var mountCommand: @MainActor (URL, URL, @escaping FileSystemCompletion<URL>) throws -> Void = NativeFileSystemMount.mountCommand
    var unmount: @MainActor (URL, @escaping FileSystemCompletion<Void>) -> Void = NativeFileSystemMount.unmount
    var entries: @MainActor () -> [MountEntry] = { NativeFileSystemMountTable.entries() }
    var capacity: @Sendable (URL) -> MountEntry? = { NativeFileSystemMountTable.capacity($0) }
    var openSettings: @MainActor () -> Bool = NativeFileSystemMount.openSettings
    var savedConnections: @MainActor () throws -> [Connection] = {
      try ConnectionRepository(location: RuntimeStorage.current.location).load()
    }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  }

  private struct CapacityKey: Hashable, Sendable {
    let path: URL
    let filesystemID: Data
  }
  private let location: any StorageLocation
  private let operations: Operations
  private let logger = Logger(subsystem: "com.seaony.Diskit", category: "mount")
  private var availableCapacity: [CapacityKey: Int64] = [:]
  private var refreshingCapacity = Set<CapacityKey>()
  private struct PendingMount {
    var callerFinished = false
    var nativeFinished = false
  }
  private var pendingMounts: [UUID: PendingMount] = [:]
  private var mountWaiters: [UUID: FileSystemCompletion<Void>] = [:]
  private var cacheMaintenance = false

  var hasActiveVolumesOrMounts: Bool {
    !pendingMounts.isEmpty || operations.entries().contains { $0.type == "diskit" }
  }

  convenience init(location: any StorageLocation = RuntimeStorage.current.location) {
    self.init(location: location, operations: Operations())
  }

  init(location: any StorageLocation, operations: Operations) {
    self.location = location
    self.operations = operations
  }

  func extensionStatus() async -> FileSystemExtensionState {
    guard operations.sharedStorageAvailable() else { return .unavailable }
    do {
      let enabled = try await FileSystemRequest<Bool?>(sleep: operations.sleep).run(
        timeout: .seconds(RemoteTimeout.deviceRequest), start: operations.enabled)
      guard let enabled else { return .unavailable }
      return enabled ? .enabled : .disabled
    } catch {
      log(error, operation: "extension-status")
      return .unavailable
    }
  }

  func openSettings() -> Bool { operations.openSettings() }

  func shares(host: String, user: String, password: String) async throws -> [String] {
    throw RemoteError.unsupported
  }

  func test(_ connection: Connection, password: String) async throws {
    guard try operations.savedConnections().contains(connection) else {
      throw FileSystemMountError.unsavedConnection
    }
    if mounted(connection) != nil { return }
    let url = try await mount(connection, password: password)
    try await unmount(url)
  }

  func mount(_ connection: Connection, password: String) async throws -> URL {
    guard !cacheMaintenance else { throw ConnectionError.busy }
    let address = try FileSystemAddress.url(for: connection)
    try Task.checkCancellation()
    let status = await extensionStatus()
    try Task.checkCancellation()
    guard !cacheMaintenance else { throw ConnectionError.busy }
    switch status {
    case .enabled: break
    case .disabled:
      logger.notice("扩展未启用，拒绝挂载 id=\(connection.id.uuidString, privacy: .public)")
      throw FileSystemMountError.disabled
    case .checking, .unavailable:
      logger.notice("扩展不可用，拒绝挂载 id=\(connection.id.uuidString, privacy: .public)")
      throw FileSystemMountError.unavailable
    }
    try Task.checkCancellation()
    if let existing = mounted(connection) { return existing.url }
    logger.info("开始挂载 id=\(connection.id.uuidString, privacy: .public) kind=\(connection.kind.rawValue, privacy: .public)")
    do {
      let url: URL
      do { url = try await mountOnce(connection, address: address) }
      catch where FileSystemMountError.isConflictingExtension(error) {
        // 系统拒绝这次启动时会顺手清掉旧登记，稍等再挂一次就能成功，不让用户手动重试。
        log(error, operation: "mount-conflict-retry", path: connection.id.uuidString)
        try await operations.sleep(.seconds(1))
        guard !cacheMaintenance else { throw ConnectionError.busy }
        do { url = try await mountOnce(connection, address: address) }
        catch where FileSystemMountError.isConflictingExtension(error) { throw FileSystemMountError.conflictingExtension }
      }
      if Task.isCancelled {
        try await unmount(url)
        throw CancellationError()
      }
      logger.info("挂载成功 id=\(connection.id.uuidString, privacy: .public) path=\(url.path, privacy: .public)")
      return url
    } catch {
      log(error, operation: "mount", path: connection.id.uuidString)
      throw error
    }
  }

  private func mountOnce(_ connection: Connection, address: URL) async throws -> URL {
    // macOS 27 的系统挂载用位置名称在 /Volumes 下建目录，名称带中文等非英文字符时会失败（errno 22），
    // 这时改用 mount 命令挂到 Diskit 自己的目录；Finder 显示的盘名取自最后一级目录名，所以用位置名称命名。
    let point = operations.usesClient() && connection.name.allSatisfy(\.isASCII) ? nil : try prepareMountPoint(connection)
    var started = false
    let requestID = UUID()
    defer { finishMount(requestID, caller: true) }
    let request = FileSystemRequest<URL>(
      sleep: operations.sleep,
      lateSuccess: { [self] url in await cleanUpLateMount(url) },
      nativeCompleted: { [weak self] in self?.finishMount(requestID, native: true) })
    do {
      // 首次 USB 授权可等 60 秒，不能套用普通设备请求的 15 秒期限。
      return try await request.run(timeout: .seconds(90)) { completion in
        guard !cacheMaintenance else { throw ConnectionError.busy }
        pendingMounts[requestID] = PendingMount()
        let received: FileSystemCompletion<URL> = { result in
          // 先等系统结束，失败后只删空挂载点；取消时不能提前撤掉正在使用的目录。
          if case .failure = result, let point { Self.removeMountPoint(point) }
          completion(result)
        }
        if let point { try operations.mountCommand(address, point, received) }
        else { try operations.mountClient(address, received) }
        started = true
      }
    } catch {
      if !started, let point { Self.removeMountPoint(point) }
      throw error
    }
  }

  func unmount(_ url: URL) async throws {
    logger.info("开始推出 path=\(url.path, privacy: .public)")
    do {
      // 已经发起的推出会继续完成，调用者取消也不能让卷留在后台。
      try await Task { @MainActor in
        try await FileSystemRequest<Void>(sleep: operations.sleep).run(
          timeout: .seconds(RemoteTimeout.deviceRequest)) { operations.unmount(url, $0) }
      }.value
      didUnmount(url)
      logger.info("推出成功 path=\(url.path, privacy: .public)")
    } catch {
      log(error, operation: "unmount", path: url.path)
      throw error
    }
  }

  func unmountAll(onFailure: ((URL, Error) -> Void)? = nil) async throws {
    try await waitForPendingMounts()
    var firstError: Error?
    for volume in mountedVolumes() {
      do {
        try await unmount(volume.url)
      } catch {
        onFailure?(volume.url, error)
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }

  func settlePendingMounts() async throws { try await waitForPendingMounts() }

  func beginCacheMaintenance() async throws {
    guard !cacheMaintenance else { throw ConnectionError.busy }
    cacheMaintenance = true
    do { try await unmountAll() } catch {
      cacheMaintenance = false
      throw error
    }
  }

  func endCacheMaintenance() { cacheMaintenance = false }

  private func finishMount(_ id: UUID, caller: Bool = false, native: Bool = false) {
    guard var pending = pendingMounts[id] else { return }
    pending.callerFinished = pending.callerFinished || caller
    pending.nativeFinished = pending.nativeFinished || native
    if pending.callerFinished && pending.nativeFinished { pendingMounts.removeValue(forKey: id) }
    else { pendingMounts[id] = pending }
    guard pendingMounts.isEmpty else { return }
    let waiters = Array(mountWaiters.values)
    mountWaiters.removeAll()
    for waiter in waiters { waiter(.success(())) }
  }

  private func waitForPendingMounts() async throws {
    guard !pendingMounts.isEmpty else { return }
    let id = UUID()
    defer { mountWaiters.removeValue(forKey: id) }
    do {
      try await FileSystemRequest<Void>(sleep: operations.sleep).run(timeout: .seconds(90)) { completion in
        if pendingMounts.isEmpty { completion(.success(())) }
        else { mountWaiters[id] = completion }
      }
    } catch {
      log(error, operation: "wait-pending-mounts")
      throw error
    }
  }

  private func cleanUpLateMount(_ url: URL) async {
    logger.notice("清理取消后的迟到挂载 path=\(url.path, privacy: .public)")
    // 由退出前的等待统一计时；清理超时不能当作原生操作已经结束。
    await withCheckedContinuation { continuation in
      operations.unmount(url) { result in
        Task { @MainActor in
          switch result {
          case .success: self.didUnmount(url)
          case .failure(let error): self.log(error, operation: "late-mount-cleanup", path: url.path)
          }
          continuation.resume()
        }
      }
    }
  }

  private func didUnmount(_ url: URL) {
    availableCapacity = availableCapacity.filter { $0.key.path != url.standardizedFileURL }
    let root = location.dataDirectory.appending(path: "Mounts").standardizedFileURL
    if url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root { Self.removeMountPoint(url) }
  }

  func isFileSystemVolume(_ url: URL) -> Bool {
    operations.entries().contains { $0.type == "diskit" && $0.path.standardizedFileURL == url.standardizedFileURL }
  }

  func mountedVolumes() -> [MountedShare] {
    operations.entries().filter(\.isDiskitVolume).map(mountedShare)
  }

  func mounted(_ connection: Connection) -> MountedShare? {
    operations.entries().first { $0.matches(connection) }.map(mountedShare)
  }

  func refreshMounted(_ connection: Connection) async -> MountedShare? {
    guard let entry = operations.entries().first(where: { $0.matches(connection) }) else { return nil }
    let key = CapacityKey(path: entry.path.standardizedFileURL, filesystemID: entry.filesystemID)
    guard refreshingCapacity.insert(key).inserted else { return mounted(connection) }
    let capacity = operations.capacity
    let request = FileSystemRequest<Int64?>(sleep: operations.sleep)
    let value = try? await request.run(timeout: .seconds(RemoteTimeout.deviceRequest)) { completion in
      Task.detached(priority: .utility) {
        let read = capacity(key.path)
        await MainActor.run { [weak self] in
          guard let self else { completion(.success(nil)); return }
          refreshingCapacity.remove(key)
          let latest = operations.entries().first { $0.matches(connection) && $0.path.standardizedFileURL == key.path }
          guard read?.filesystemID == key.filesystemID, read?.matches(connection) == true,
            latest?.filesystemID == key.filesystemID
          else {
            availableCapacity.removeValue(forKey: key)
            completion(.success(nil))
            return
          }
          availableCapacity[key] = read?.availableBytes
          completion(.success(read?.availableBytes))
        }
      }
    }
    if value == nil, refreshingCapacity.contains(key) { availableCapacity.removeValue(forKey: key) }
    return mounted(connection)
  }

  private func mountedShare(_ entry: MountEntry) -> MountedShare {
    let key = CapacityKey(path: entry.path.standardizedFileURL, filesystemID: entry.filesystemID)
    availableCapacity = availableCapacity.filter { $0.key.path != key.path || $0.key == key }
    return MountedShare(url: entry.path, availableBytes: availableCapacity[key] ?? entry.availableBytes)
  }

  // 挂载点是 Mounts/<编号>/<位置名称>：编号保证不和别的位置撞，名称给 Finder 显示
  private func prepareMountPoint(_ connection: Connection) throws -> URL {
    let root = location.dataDirectory.appending(path: "Mounts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let parent = root.appending(path: connection.id.uuidString.lowercased(), directoryHint: .isDirectory)
    let point = parent.appending(path: Self.mountDirectoryName(connection.name), directoryHint: .isDirectory)
    for directory in [root, parent] { try Self.prepareDirectory(directory) }
    // 先删掉上次留下的空目录（改名前的、只差大小写的都算），再建这次的；不是空目录说明里面有东西，不能挂在上面
    for name in try FileManager.default.contentsOfDirectory(atPath: parent.path) {
      _ = rmdir(parent.appending(path: name).path)
    }
    try Self.prepareDirectory(point)
    guard try FileManager.default.contentsOfDirectory(atPath: parent.path).count == 1,
      try FileManager.default.contentsOfDirectory(atPath: point.path).isEmpty
    else { throw POSIXError(.ENOTEMPTY) }
    return point
  }

  nonisolated private static func prepareDirectory(_ directory: URL) throws {
    var info = stat()
    if lstat(directory.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
    } else {
      guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
  }

  // 目录名不能有斜杠，冒号在 Finder 里会显示成斜杠；太长时截到 255 字节以内
  nonisolated static func mountDirectoryName(_ name: String) -> String {
    var value = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while value.utf8.count > 255 { value.removeLast() }
    return value.isEmpty || value == "." || value == ".." ? "Diskit" : value
  }

  // 只删空目录：先删名称目录，再删编号目录
  nonisolated private static func removeMountPoint(_ point: URL) {
    _ = rmdir(point.path)
    _ = rmdir(point.deletingLastPathComponent().path)
  }

  private func log(_ error: Error, operation: String, path: String = "") {
    logger.error("\(operation, privacy: .public) path=\(path, privacy: .public) \(ErrorDiagnostics.summary(error), privacy: .public)")
  }
}
