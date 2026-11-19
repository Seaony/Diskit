import Core
import Foundation
import Synchronization

@MainActor public final class RicohProvider: RemoteFileProvider {
  private nonisolated let deletionAllowed = Mutex(false)
  public nonisolated var capabilities: ProviderCapabilities {
    ProviderCapabilities(
      canWrite: false, canRename: false, canMove: false,
      canDelete: deletionAllowed.withLock { $0 }, supportsRangeRead: true)
  }
  private let adapter: any RicohCameraAdapter
  private var connected = false
  public init(adapter: any RicohCameraAdapter) { self.adapter = adapter }

  public static func make(serial: String) async throws -> RicohProvider {
    try await make(identifier: serial)
  }

  public static func make(identifier: String) async throws -> RicohProvider {
    let discovery = RicohDiscovery()
    try await discovery.enumerate()
    guard !identifier.isEmpty, let camera = discovery.camera(identifier: identifier) else {
      discovery.stop()
      throw RemoteError.notConnected
    }
    return RicohProvider(adapter: ImageCaptureAdapter(camera: camera, discovery: discovery))
  }

  public func connect() async throws {
    guard !connected else { return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    do {
      try await adapter.open(until: deadline)
      connected = true
      _ = try await current(until: deadline)
    } catch {
      PackageDiagnostics.failure(error, category: .ricohGR, operation: .connect)
      await adapter.close()
      connected = false
      throw error
    }
  }
  public func disconnect() async {
    connected = false
    deletionAllowed.withLock { $0 = false }
    await adapter.close()
  }
  public func spaceInfo() async throws -> SpaceInfo {
    let snapshot = try await current()
    var total: Int64 = 0
    var free: Int64 = 0
    for storage in snapshot.storages {
      let sum = total.addingReportingOverflow(storage.total)
      let available = free.addingReportingOverflow(storage.free)
      guard !sum.overflow, !available.overflow else { throw RemoteError.protocolError }
      total = sum.partialValue
      free = available.partialValue
    }
    return SpaceInfo(total: total, used: total - free)
  }
  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let index = try index(await current())
    guard let node = index[path.value] else { throw RemoteError.posix(ENOENT) }
    guard node.item.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return index.values.map(\.item).filter { item in
      let parts = item.path.value.split(separator: "/").dropLast()
      return item.path != path && "/" + parts.joined(separator: "/") == path.value
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    guard let node = try index(await current())[path.value] else { throw RemoteError.posix(ENOENT) }
    return node.item
  }
  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    guard let node = try index(await current())[path.value] else { throw RemoteError.posix(ENOENT) }
    guard !node.item.isDirectory, let handle = node.handle else { throw RemoteError.posix(EISDIR) }
    let start = range?.lowerBound ?? 0
    let end = min(range?.upperBound ?? node.item.size, node.item.size)
    guard start >= 0, start <= end else { throw RemoteError.posix(EINVAL) }
    let cursor = RicohReadCursor(adapter: adapter, handle: handle, start: start, end: end)
    return AsyncThrowingStream(unfolding: { try await cursor.next() })
  }
  public func write(_ path: RemotePath, from localFile: URL) async throws {
    throw RemoteError.posix(EROFS)
  }
  public func makeDirectory(_ path: RemotePath) async throws { throw RemoteError.posix(EROFS) }
  public func move(_ from: RemotePath, to: RemotePath) async throws {
    throw RemoteError.posix(EROFS)
  }
  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    guard let node = try index(await current(until: deadline))[path.value] else {
      throw RemoteError.posix(ENOENT)
    }
    guard !node.item.isDirectory, let handle = node.handle else { throw RemoteError.posix(EACCES) }
    guard adapter.canDelete else { throw RemoteError.posix(EACCES) }
    do { try await adapter.delete(handles: [handle], until: deadline) } catch {
      PackageDiagnostics.failure(error, category: .ricohGR, operation: .remove)
      throw RicohErrorMapper.map(error)
    }
  }
  private func current(
    until deadline: ContinuousClock.Instant = .now.advanced(
      by: .seconds(RemoteTimeout.deviceRequest))
  ) async throws -> RicohSnapshot {
    guard connected else { throw RemoteError.failed(EIO, L("相机还没连接")) }
    let snapshot: RicohSnapshot
    do { snapshot = try await adapter.snapshot(until: deadline) } catch {
      PackageDiagnostics.failure(error, category: .ricohGR, operation: .snapshot)
      throw error
    }
    deletionAllowed.withLock { $0 = adapter.canDelete }
    guard !snapshot.storages.isEmpty else { throw RemoteError.posix(ENODEV) }
    for storage in snapshot.storages {
      guard storage.total >= 0, storage.free >= 0, storage.free <= storage.total else {
        throw RemoteError.protocolError
      }
    }
    return snapshot
  }
  private struct Node {
    let item: RemoteItem
    let handle: UInt32?
  }
  private func index(_ snapshot: RicohSnapshot) throws -> [String: Node] {
    var result: [String: Node] = [:]
    func folder(_ path: RemotePath) -> RemoteItem {
      RemoteItem(
        path: path, name: path.value.split(separator: "/").last.map(String.init) ?? "/",
        isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0))
    }
    result["/"] = Node(item: folder(try RemotePath("/")), handle: nil)
    var roots: [UInt32: String] = [:]
    for storage in snapshot.storages {
      let root = "/" + storage.kind.name
      guard result[root] == nil, roots[storage.id] == nil else { throw RemoteError.protocolError }
      roots[storage.id] = root
      result[root] = Node(item: folder(try RemotePath(root)), handle: nil)
    }
    var explicitPaths = Set<String>()
    var handles = Set<UInt32>()
    for entry in snapshot.entries {
      guard let root = roots[entry.storageID], !entry.relativePath.isEmpty,
        !entry.relativePath.hasPrefix("/"), entry.size >= 0
      else { throw RemoteError.protocolError }
      let path = try RemotePath(root + "/" + entry.relativePath)
      guard path.value == root + "/" + entry.relativePath else { throw RemoteError.invalidPath }
      guard explicitPaths.insert(path.value).inserted else { throw RemoteError.protocolError }
      if let existing = result[path.value], !existing.item.isDirectory || !entry.isDirectory {
        throw RemoteError.protocolError
      }
      if !entry.isDirectory, let handle = Optional(entry.handle) {
        guard handle != 0, handles.insert(handle).inserted else { throw RemoteError.protocolError }
      }
      var parent = ""
      for part in path.value.split(separator: "/").dropLast() {
        parent += "/" + part
        if let existing = result[parent], !existing.item.isDirectory {
          throw RemoteError.protocolError
        }
        if result[parent] == nil {
          result[parent] = Node(item: folder(try RemotePath(parent)), handle: nil)
        }
      }
      let item = RemoteItem(
        path: path, name: path.value.split(separator: "/").last.map(String.init) ?? "",
        isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified)
      result[path.value] = Node(item: item, handle: entry.handle)
    }
    return result
  }
}

private actor RicohReadCursor {
  private let adapter: any RicohCameraAdapter
  private let handle: UInt32
  private var offset: Int64
  private let end: Int64
  init(adapter: any RicohCameraAdapter, handle: UInt32, start: Int64, end: Int64) {
    self.adapter = adapter
    self.handle = handle
    self.offset = start
    self.end = end
  }
  func next() async throws -> Data? {
    try Task.checkCancellation()
    guard offset < end else { return nil }
    let length = Int(min(1_048_576, end - offset))
    do {
      let data = try await adapter.read(handle: handle, offset: offset, length: length)
      guard !data.isEmpty, data.count <= length else {
        throw RemoteError.failed(
          EIO, LF("相机返回的数据长度不对（收到 %lld 字节，最多 %lld）", Int64(data.count), Int64(length)))
      }
      offset += Int64(data.count)
      return data
    } catch {
      PackageDiagnostics.failure(error, category: .ricohGR, operation: .download)
      throw error
    }
  }
}
