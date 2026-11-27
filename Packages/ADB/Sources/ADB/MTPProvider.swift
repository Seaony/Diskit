import Core
import Foundation
import OSLog
import Synchronization

// 用 MTP（文件传输）读写安卓设备，不需要打开 USB 调试。
// MTP 按对象句柄寻址，这里把 Finder 的路径一级级映射到句柄，并缓存列过的目录
public actor MTPProvider: RemoteFileProvider {
  // 连上后按设备声明支持的操作改：不支持改名的设备不能放行“传暂存名、删旧、改名”的覆盖流程，否则会删掉原件
  private nonisolated let allowed = Mutex(
    ProviderCapabilities(
      canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true))
  public nonisolated var capabilities: ProviderCapabilities { allowed.withLock { $0 } }

  struct Storage: Equatable {
    var id: UInt32
    var name: String
  }
  // handle 为 root 表示某个存储的根目录；parent 是设备报的父对象句柄，存储根目录下为 0
  struct Entry: Equatable {
    var storage: UInt32
    var handle: UInt32
    var parent: UInt32 = 0
    var isDirectory: Bool
    var item: RemoteItem
  }
  enum Node {
    // 有多个存储（内部存储、SD 卡）时，卷根目录下每个存储是一个文件夹
    case top
    case object(Entry)
  }

  static let root: UInt32 = 0xFFFF_FFFF
  // 顺序读整个文件时每次向设备要 4 MiB
  static let readChunk: Int64 = 4 << 20
  // 列过的目录在这段时间内直接拿缓存判断“没有这个文件”，免得 Finder 每次探测都重列整个目录
  static let listingTTL: TimeInterval = 5

  // 设备睡眠、锁屏或还没选 USB 用途时不收命令：连接时最多等这么久让用户解锁，和 ADB 等手机授权一样长
  static let wakeTimeout: TimeInterval = 60

  private let name: String
  private let wakeTimeout: TimeInterval
  private let retryInterval: Duration
  private let open: @Sendable () async throws -> MTPSession
  private var session: MTPSession?
  private var info: MTPDeviceInfo?
  private var storages: [Storage] = []
  private var entries: [String: Entry] = [:]
  private var listedAt: [String: ContinuousClock.Instant] = [:]
  private var busy = false
  private var connecting = false
  private static let logger = Logger(subsystem: "com.seaony.Diskit", category: "MTP")

  init(
    name: String = "Android", wakeTimeout: TimeInterval = MTPProvider.wakeTimeout,
    retryInterval: Duration = .seconds(1), open: @escaping @Sendable () async throws -> MTPSession
  ) {
    self.name = name
    self.wakeTimeout = wakeTimeout
    self.retryInterval = retryInterval
    self.open = open
  }

  public static func make(for connection: Connection) -> MTPProvider {
    let params = connection.params
    return MTPProvider(name: connection.name) {
      // 每次重新找设备：拔插后系统注册表里的编号会变
      let device = try MTPUSB.select(params: params, devices: MTPUSB.devices())
      return MTPSession(channel: try SystemUSBChannel(registryID: device.registryID, role: .mtp))
    }
  }

  // 设备自己报的型号名（如“Leaf5”），连上后才有
  public var deviceModel: String? { info?.model }

  // MARK: 连接

  public func connect() async throws {
    guard session == nil else { return }
    guard !connecting else { throw RemoteError.posix(EBUSY) }
    connecting = true
    defer { connecting = false }
    do {
      let (session, info, storages) = try await wake()
      self.storages = storages
      self.info = info
      self.session = session
      allowed.withLock {
        $0 = ProviderCapabilities(
          canWrite: info.supports(.sendObjectInfo) && info.supports(.sendObject),
          canRename: info.supports(.setObjectPropValue), canMove: info.supports(.moveObject),
          canDelete: info.supports(.deleteObject), supportsRangeRead: true)
      }
      entries = [:]
      listedAt = [:]
      Self.logger.info(
        "MTP 已连接：\(info.manufacturer, privacy: .public) \(info.model, privacy: .public)，存储 \(self.storages.count)")
    } catch {
      PackageDiagnostics.failure(error, category: .mtp, operation: .connect)
      throw error
    }
  }

  // 打开接口、开会话、读存储列表。设备不收命令（睡眠、锁屏、USB 用途没选“文件传输”），
  // 或能答话但还没开放存储（有的设备锁屏时这样），就关掉接口隔一秒再试，用户一解锁就连上；
  // 等满 wakeTimeout 还不行才报错，说清该在设备上做什么
  private func wake() async throws -> (MTPSession, MTPDeviceInfo, [Storage]) {
    let deadline = ContinuousClock.now + .seconds(wakeTimeout)
    var waited = false
    while true {
      let session = try await open()
      do {
        await session.reset()
        let info = try await session.deviceInfo(commandTimeout: 2)
        let start = try await session.raw(.openSession, [1])
        if start.code == MTPResponse.sessionAlreadyOpen {
          try await session.run(.closeSession)
          try await session.run(.openSession, [1])
        } else if start.code != MTPResponse.ok {
          throw MTPResponse.error(start.code, operation: .openSession)
        }
        let storages = try await loadStorages(session)
        if !storages.isEmpty {
          if waited { Self.logger.info("MTP 设备已解锁，开始连接") }
          return (session, info, storages)
        }
        _ = try? await session.raw(.closeSession)
        await session.close()
        guard ContinuousClock.now < deadline else {
          throw RemoteError.failed(
            EACCES, L("设备没有提供可访问的存储。请解锁设备，并在设备的 USB 选项里选“文件传输”后重试"))
        }
      } catch RemoteError.posix(ETIMEDOUT) {
        await session.close()
        guard ContinuousClock.now < deadline else {
          // 不用 ETIMEDOUT：卷后端会把它当断线改写成“连接已断开”，挂载面板就看不到这句说明
          throw RemoteError.failed(
            EHOSTDOWN,
            LF("“%@”没有回应。请唤醒并解锁设备，设备上弹出 USB 用途选择时选“文件传输”；已经解锁还不行就重新插拔数据线", name))
        }
      } catch {
        await session.close()
        throw error
      }
      if !waited { Self.logger.notice("MTP 设备还没准备好，等待解锁") }
      waited = true
      try await Task.sleep(for: retryInterval)
    }
  }

  public func disconnect() async {
    guard let session else { return }
    self.session = nil
    if await !session.broken { _ = try? await session.raw(.closeSession) }
    await session.close()
    entries = [:]
    listedAt = [:]
  }

  private func loadStorages(_ session: MTPSession) async throws -> [Storage] {
    var reader = MTPReader(try await session.run(.getStorageIDs, receive: .collect).data)
    var result: [Storage] = []
    var used: Set<String> = []
    for id in try reader.u32Array() where id & 0xFFFF != 0 {  // 低 16 位为 0 表示存储没插上
      let storage = try MTPDataset.storageInfo(
        try await session.run(.getStorageInfo, [id], receive: .collect).data)
      var name = [storage.description, storage.label].first { !$0.isEmpty }
        ?? LF("存储 %@", String(result.count + 1))
      name = name.replacingOccurrences(of: "/", with: "-")
      var unique = name
      var index = 2
      while used.contains(unique) {
        unique = name + " \(index)"
        index += 1
      }
      used.insert(unique)
      result.append(Storage(id: id, name: unique))
    }
    return result
  }

  // 同一时间只做一项操作；事务半路断掉的会话作废，下次由上层重连
  private func perform<Value>(
    _ operation: DiagnosticOperation, _ body: (MTPSession) async throws -> Value
  ) async throws -> Value {
    guard let session else { throw RemoteError.notConnected }
    guard !busy else { throw RemoteError.posix(EBUSY) }
    busy = true
    defer { busy = false }
    do {
      return try await body(session)
    } catch {
      PackageDiagnostics.failure(error, category: .mtp, operation: operation)
      if await session.broken { await drop(session) }
      throw error
    }
  }

  private func drop(_ session: MTPSession) async {
    guard self.session === session else { return }
    self.session = nil
    entries = [:]
    listedAt = [:]
    await session.close()
  }

  // MARK: 路径和句柄

  private func storageRoot(_ storage: Storage) throws -> Entry {
    let top = try RemotePath("/")
    let path = storages.count == 1 ? top : try top.appending(storage.name)
    return Entry(
      storage: storage.id, handle: Self.root, isDirectory: true,
      item: RemoteItem(
        path: path, name: storages.count == 1 ? "" : storage.name, isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0)))
  }

  private func node(_ path: RemotePath, _ session: MTPSession) async throws -> Node {
    if path.value == "/" {
      return storages.count == 1 ? .object(try storageRoot(storages[0])) : .top
    }
    if storages.count > 1, path.parent.value == "/" {
      guard let storage = storages.first(where: { $0.name == path.basename }) else {
        throw RemoteError.posix(ENOENT)
      }
      return .object(try storageRoot(storage))
    }
    if let entry = entries[path.value] { return .object(entry) }
    let parent = try await directory(path.parent, session)
    let listed = listedAt[path.parent.value].map {
      $0.duration(to: .now) < .seconds(Self.listingTTL)
    } ?? false
    if !listed { _ = try await children(of: parent, session) }
    guard let entry = entries[path.value] else { throw RemoteError.posix(ENOENT) }
    return .object(entry)
  }

  // 要求是某个存储里的文件夹（卷根目录在多存储时不能直接放文件）
  private func directory(_ path: RemotePath, _ session: MTPSession) async throws -> Entry {
    switch try await node(path, session) {
    case .top: throw RemoteError.posix(EACCES)
    case .object(let entry):
      guard entry.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      return entry
    }
  }

  private func object(_ path: RemotePath, _ session: MTPSession) async throws -> Entry {
    guard case .object(let entry) = try await node(path, session) else {
      throw RemoteError.posix(EACCES)
    }
    return entry
  }

  // 核对缓存：设备上被改名或移走的对象句柄可能不变，不核对就会读错、改错文件。
  // deep 时从上往下逐级核对整条路径（改动前用），上一级文件夹在设备上改了名，旧路径就找不到了
  private func verified(_ path: RemotePath, _ session: MTPSession, deep: Bool = false) async throws
    -> Node
  {
    if deep, path.value != "/", !(storages.count > 1 && path.parent.value == "/") {
      _ = try await verified(path.parent, session, deep: true)
    }
    let found = try await node(path, session)
    guard case .object(let entry) = found, entry.handle != Self.root else { return found }
    var info: MTPObjectInfo?
    do {
      info = try MTPDataset.objectInfo(
        try await session.run(.getObjectInfo, [entry.handle], receive: .collect).data)
    } catch let error as RemoteError where error.errno == ENOENT {}
    if let info, info.name == entry.item.name, info.parent == entry.parent,
      info.storageID == entry.storage
    {
      var updated = entry
      if !info.isDirectory, info.compressedSize != UInt32.max {
        updated.item.size = Int64(info.compressedSize)
      }
      if let modified = info.modified { updated.item.modified = modified }
      remember(updated)
      return .object(updated)
    }
    // 对不上就重列上一层，按最新的结果找
    forget(path)
    listedAt[path.parent.value] = nil
    return try await node(path, session)
  }

  private func verifiedObject(_ path: RemotePath, _ session: MTPSession, deep: Bool = true)
    async throws -> Entry
  {
    guard case .object(let entry) = try await verified(path, session, deep: deep) else {
      throw RemoteError.posix(EACCES)
    }
    return entry
  }

  private func verifiedDirectory(_ path: RemotePath, _ session: MTPSession) async throws -> Entry {
    switch try await verified(path, session, deep: true) {
    case .top: throw RemoteError.posix(EACCES)
    case .object(let entry):
      guard entry.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      return entry
    }
  }

  // 只在上一级已经核对过之后用
  private func exists(_ path: RemotePath, _ session: MTPSession) async throws -> Bool {
    do {
      _ = try await verified(path, session)
      return true
    } catch let error as RemoteError where error.errno == ENOENT {
      return false
    }
  }

  private func children(of parent: Entry, _ session: MTPSession) async throws -> [RemoteItem] {
    var reader = MTPReader(
      try await session.run(
        .getObjectHandles, [parent.storage, 0, parent.handle], receive: .collect
      ).data)
    let handles = try reader.u32Array()
    let directory = parent.item.path
    var items: [RemoteItem] = []
    var fresh: [String: Entry] = [:]
    for handle in handles {
      let info: MTPObjectInfo
      do {
        info = try MTPDataset.objectInfo(
          try await session.run(.getObjectInfo, [handle], receive: .collect).data)
      } catch let error as RemoteError where error.errno == ENOENT {
        continue  // 列的过程中被删掉了
      }
      // 名字里有 / 或是 . .. 的对象 Finder 表示不了；同名的只保留第一个
      guard !info.name.isEmpty, !info.name.contains("/"), info.name != ".", info.name != "..",
        let path = try? directory.appending(info.name), fresh[path.value] == nil
      else {
        Self.logger.notice("跳过无法表示的 MTP 对象 \(handle)：\(info.name, privacy: .private)")
        continue
      }
      var size = Int64(info.compressedSize)
      // 超过 4 GB 的文件 ObjectInfo 里只写 0xFFFFFFFF，真实大小要单独问
      if !info.isDirectory, info.compressedSize == UInt32.max,
        self.info?.supports(.getObjectPropValue) == true
      {
        var value = MTPReader(
          try await session.run(
            .getObjectPropValue, [handle, UInt32(MTPProperty.objectSize)], receive: .collect
          ).data)
        size = Int64(clamping: try value.u64())
      }
      let item = RemoteItem(
        path: path, name: info.name, isDirectory: info.isDirectory,
        size: info.isDirectory ? 0 : size, modified: info.modified ?? Date(timeIntervalSince1970: 0))
      fresh[path.value] = Entry(
        storage: info.storageID, handle: handle, parent: info.parent, isDirectory: info.isDirectory,
        item: item)
      items.append(item)
    }
    // 只替换这一层的缓存；子文件夹没了或句柄变了，它下面的缓存一起作废
    let stale = entries.filter {
      RemotePath.parentValue($0.key) == directory.value && fresh[$0.key]?.handle != $0.value.handle
    }.keys
    for key in stale { if let path = try? RemotePath(key) { forget(path) } }
    entries = entries.filter { RemotePath.parentValue($0.key) != directory.value }
    entries.merge(fresh) { _, new in new }
    listedAt[directory.value] = .now
    return items
  }

  private func forget(_ path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    entries = entries.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
    listedAt = listedAt.filter { $0.key != path.value && !$0.key.hasPrefix(prefix) }
  }

  private func remember(_ entry: Entry) {
    entries[entry.item.path.value] = entry
  }

  // MARK: 浏览

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try await perform(.fileOperation) { session in
      switch try await node(path, session) {
      case .top: return try storages.map { try storageRoot($0).item }
      case .object(let entry):
        guard entry.isDirectory else { throw RemoteError.posix(ENOTDIR) }
        return try await children(of: entry, session)
      }
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try await perform(.fileOperation) { session in
      // 设备上的文件可能被别处改过，取一次最新信息
      switch try await verified(path, session) {
      case .top:
        return RemoteItem(
          path: path, name: "", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
      case .object(let entry): return entry.item
      }
    }
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try await perform(.request) { session in
      var total: UInt64 = 0
      var free: UInt64 = 0
      for storage in storages {
        let info = try MTPDataset.storageInfo(
          try await session.run(.getStorageInfo, [storage.id], receive: .collect).data)
        total &+= info.capacity
        free &+= min(info.free, info.capacity)
      }
      return SpaceInfo(
        total: Int64(clamping: total), used: Int64(clamping: total - free),
        available: Int64(clamping: free))
    }
  }

  // MARK: 读取

  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    // 先核对，再用这一个对象的句柄和大小去读，设备上同名文件被换掉时不会读到旧对象
    let entry = try await perform(.download) { try await verifiedObject(path, $0, deep: false) }
    guard !entry.isDirectory else { throw RemoteError.posix(EISDIR) }
    if let range {
      let data = try await readPart(entry, offset: range.lowerBound, count: range.count)
      return AsyncThrowingStream {
        $0.yield(data)
        $0.finish()
      }
    }
    let size = entry.item.size
    // 只有 32 位分段读的设备读不到 4 GB 以后的部分，这时整个对象一次读完
    let partial =
      info?.supports(.getPartialObject64) == true
      || (info?.supports(.getPartialObject) == true && size <= Int64(UInt32.max))
    guard partial else { return try await readWhole(entry) }
    // 分段读完整个文件，每段是一个独立事务，中途停下不会弄坏会话
    let cursor = MTPReadCursor(size: size) { offset, count in
      try await self.readPart(entry, offset: offset, count: count)
    }
    return AsyncThrowingStream(unfolding: { try await cursor.next() })
  }

  func readPart(_ entry: Entry, offset: Int64, count: Int) async throws -> Data {
    guard count > 0 else { return Data() }
    return try await perform(.download) { session in
      var result = Data()
      var position = offset
      var left = Int64(count)
      while left > 0 {
        let piece = UInt32(min(left, Int64(UInt32.max - 1)))
        let data: Data
        if info?.supports(.getPartialObject64) == true {
          data = try await session.run(
            .getPartialObject64,
            [entry.handle, UInt32(truncatingIfNeeded: position), UInt32(position >> 32), piece],
            receive: .collect
          ).data
        } else if info?.supports(.getPartialObject) == true, position + Int64(piece) <= Int64(UInt32.max) {
          data = try await session.run(
            .getPartialObject, [entry.handle, UInt32(position), piece], receive: .collect
          ).data
        } else {
          throw RemoteError.unsupported
        }
        result.append(data)
        // 读到文件末尾时设备只回实际剩下的部分
        if data.count < Int(piece) { break }
        position += Int64(data.count)
        left -= Int64(data.count)
      }
      return result
    }
  }

  // 设备不支持分段读时用 GetObject 一次读完，边收边交给 Finder
  private func readWhole(_ entry: Entry) async throws -> AsyncThrowingStream<Data, Error> {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    Task {
      do {
        _ = try await self.perform(.download) { session in
          try await session.run(
            .getObject, [entry.handle], receive: .stream({ _ = continuation.yield($0) }))
        }
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    return stream
  }

  // MARK: 写入

  // 只新建文件。覆盖已有文件由卷后端先传到暂存名、核对大小后再删旧改名，失败时暂存会露出来
  public func write(_ path: RemotePath, from localFile: URL) async throws {
    // 直接问文件系统：URL 会缓存文件属性，同一个 URL 的文件被改写后读到的还是旧大小
    let attributes = try FileManager.default.attributesOfItem(atPath: localFile.path)
    guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw RemoteError.protocolError }
    try await perform(.upload) { session in
      let parent = try await verifiedDirectory(path.parent, session)
      if try await exists(path, session) { throw RemoteError.posix(EEXIST) }
      let created = try await sendObject(
        name: path.basename, size: size, file: localFile, parent: parent, session)
      forget(path)
      remember(
        Entry(
          storage: parent.storage, handle: created, parent: Self.parentHandle(of: parent),
          isDirectory: false,
          item: RemoteItem(
            path: path, name: path.basename, isDirectory: false, size: size, modified: Date())))
    }
  }

  // 新对象的父句柄按设备的写法：存储根目录下是 0
  static func parentHandle(of directory: Entry) -> UInt32 {
    directory.handle == root ? 0 : directory.handle
  }

  private func sendObject(
    name: String, size: Int64, file: URL?, parent: Entry, _ session: MTPSession
  ) async throws -> UInt32 {
    // 带上本地文件的修改时间，Finder 里看到的时间和拷进去的文件一致
    let modified = file.flatMap {
      (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
    }
    let dataset = try MTPDataset.newObject(
      name: name, size: size, isDirectory: file == nil, modified: modified)
    let response = try await session.run(
      .sendObjectInfo, [parent.storage, parent.handle], send: .data(dataset))
    guard response.params.count >= 3 else {
      throw RemoteError.malformed(L("设备在 SendObjectInfo 的响应里没有给出新对象的句柄"))
    }
    let handle = response.params[2]
    guard let file else { return handle }
    do {
      try await session.run(.sendObject, send: .file(file, size: size), cancellable: true)
    } catch {
      // 会话还能用就把传了一半的文件删掉
      if await !session.broken { _ = try? await session.run(.deleteObject, [handle, 0]) }
      throw error
    }
    return handle
  }

  private func rename(_ handle: UInt32, to name: String, _ session: MTPSession) async throws {
    var value = Data()
    try value.appendMTP(string: name)
    try await session.run(
      .setObjectPropValue, [handle, UInt32(MTPProperty.objectFileName)], send: .data(value))
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    try await perform(.fileOperation) { session in
      let parent = try await verifiedDirectory(path.parent, session)
      if try await exists(path, session) { throw RemoteError.posix(EEXIST) }
      let handle = try await sendObject(name: path.basename, size: 0, file: nil, parent: parent, session)
      remember(
        Entry(
          storage: parent.storage, handle: handle, parent: Self.parentHandle(of: parent),
          isDirectory: true,
          item: RemoteItem(path: path, name: path.basename, isDirectory: true, size: 0, modified: Date())))
      listedAt[path.value] = .now
    }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try await perform(.remove) { session in
      let entry = try await verifiedObject(path, session)
      guard entry.handle != Self.root else { throw RemoteError.posix(EACCES) }
      if entry.isDirectory, !recursive {
        var reader = MTPReader(
          try await session.run(
            .getObjectHandles, [entry.storage, 0, entry.handle], receive: .collect
          ).data)
        guard try reader.u32Array().isEmpty else { throw RemoteError.posix(ENOTEMPTY) }
      }
      // 删除文件夹时设备会连里面的内容一起删
      try await session.run(.deleteObject, [entry.handle, 0])
      forget(path)
    }
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    try await perform(.fileOperation) { session in
      let source = try await verifiedObject(from, session)
      guard source.handle != Self.root else { throw RemoteError.posix(EACCES) }
      let target = try await verifiedDirectory(to.parent, session)
      if try await exists(to, session) { throw RemoteError.posix(EEXIST) }
      let moves = from.parent != to.parent
      if moves {
        guard info?.supports(.moveObject) == true else { throw RemoteError.unsupported }
        // MoveObject 的目标父对象用 0 表示存储根目录
        try await session.run(
          .moveObject, [source.handle, target.storage, Self.parentHandle(of: target)])
      }
      if from.basename != to.basename {
        do {
          try await rename(source.handle, to: to.basename, session)
        } catch {
          // 改名失败就把文件移回原处，Finder 还能按原路径找到它
          if moves, await !session.broken {
            _ = try? await session.run(.moveObject, [source.handle, source.storage, source.parent])
          }
          forget(from)
          forget(to)
          listedAt[from.parent.value] = nil
          listedAt[to.parent.value] = nil
          throw error
        }
      }
      forget(from)
      forget(to)
      listedAt[to.parent.value] = nil
    }
  }
}

extension RemotePath {
  // 缓存键（规范化后的路径字符串）的上一级
  static func parentValue(_ value: String) -> String {
    guard let slash = value.lastIndex(of: "/") else { return "/" }
    return slash == value.startIndex ? "/" : String(value[..<slash])
  }
}

// 顺序读整个文件：每次要一段，读到文件末尾为止
private actor MTPReadCursor {
  let size: Int64
  let read: @Sendable (Int64, Int) async throws -> Data
  var offset: Int64 = 0
  var done = false
  init(size: Int64, read: @escaping @Sendable (Int64, Int) async throws -> Data) {
    self.size = size
    self.read = read
  }
  func next() async throws -> Data? {
    guard !done, offset < size else { return nil }
    try Task.checkCancellation()
    let count = Int(min(MTPProvider.readChunk, size - offset))
    let data = try await read(offset, count)
    if data.isEmpty {
      done = true
      return nil
    }
    offset += Int64(data.count)
    return data
  }
}
