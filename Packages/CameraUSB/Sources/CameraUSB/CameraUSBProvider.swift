import Core
import Foundation
import Synchronization

@MainActor public final class CameraUSBProvider: RemoteFileProvider {
  private nonisolated let deletionAllowed = Mutex(false)
  public nonisolated var capabilities: ProviderCapabilities {
    ProviderCapabilities(
      canWrite: false, canRename: false, canMove: false,
      canDelete: deletionAllowed.withLock { $0 }, supportsRangeRead: true)
  }

  private let access: any CameraUSBAccess
  private var connected = false

  init(access: any CameraUSBAccess) {
    self.access = access

  }

  public static func make(identifier: String) async throws -> CameraUSBProvider {
    let discovery = CameraUSBDiscovery()
    try await discovery.enumerate()
    guard !identifier.isEmpty, let camera = discovery.camera(identifier: identifier) else {
      discovery.stop()
      throw RemoteError.posix(ENODEV)
    }
    return CameraUSBProvider(
      access: ImageCaptureAccess(camera: camera, discovery: discovery))
  }

  public func connect() async throws {
    guard !connected else { return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    do {
      try await access.open(until: deadline)
      connected = true
      _ = try await current(until: deadline)
    } catch {
      PackageDiagnostics.failure(error, category: .cameraUSB, operation: .connect)
      await access.close()
      connected = false
      throw error
    }
  }

  public func disconnect() async {
    connected = false
    deletionAllowed.withLock { $0 = false }
    await access.close()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    let snapshot = try await current()
    for storage in snapshot.storages {
      if let total = storage.total, total < 0 { throw RemoteError.protocolError }
      if let available = storage.available, available < 0 { throw RemoteError.protocolError }
      if let total = storage.total, let available = storage.available, available > total {
        throw RemoteError.protocolError
      }
    }
    func sum(_ values: [Int64?]) throws -> Int64? {
      var result: Int64 = 0
      for value in values {
        guard let value else { return nil }
        let next = result.addingReportingOverflow(value)
        guard !next.overflow else { throw RemoteError.protocolError }
        result = next.partialValue
      }
      return result
    }
    let total = try sum(snapshot.storages.map(\.total))
    let available = try sum(snapshot.storages.map(\.available))
    let used = total.flatMap { total in available.map { total - $0 } }
    return SpaceInfo(total: total, used: used, available: available)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let index = try makeIndex(try await current())
    guard let node = index[path.value] else { throw RemoteError.posix(ENOENT) }
    guard node.item.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return index.values.compactMap { candidate in
      guard candidate.item.path != path else { return nil }
      let parent =
        "/"
        + candidate.item.path.value.split(separator: "/").dropLast().joined(separator: "/")
      return parent == path.value ? candidate.item : nil
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    let index = try makeIndex(try await current())
    guard let node = index[path.value] else { throw RemoteError.posix(ENOENT) }
    return node.item
  }

  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    let index = try makeIndex(try await current())
    guard let node = index[path.value] else { throw RemoteError.posix(ENOENT) }
    guard !node.item.isDirectory, let handle = node.fileHandle else {
      throw RemoteError.posix(EISDIR)
    }
    let start = range?.lowerBound ?? 0
    let end = min(range?.upperBound ?? node.item.size, node.item.size)
    guard start >= 0, start <= end else { throw RemoteError.posix(EINVAL) }
    let cursor = CameraUSBReadCursor(
      access: access, handle: handle, start: start, end: end)
    return AsyncThrowingStream(unfolding: { try await cursor.next() })
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    let index = try makeIndex(try await current(until: deadline))
    guard let node = index[path.value] else { throw RemoteError.posix(ENOENT) }
    guard !node.item.isDirectory, let handle = node.fileHandle else {
      throw RemoteError.posix(EACCES)
    }
    guard capabilities.canDelete else { throw RemoteError.posix(EACCES) }
    do {
      try await access.delete(handles: [handle], until: deadline)
    } catch {
      PackageDiagnostics.failure(error, category: .cameraUSB, operation: .remove)
      throw CameraUSBErrorMapper.map(error)
    }
  }

  private func current(
    until deadline: ContinuousClock.Instant = .now.advanced(
      by: .seconds(RemoteTimeout.deviceRequest))
  ) async throws -> CameraUSBSnapshot {
    guard connected else { throw RemoteError.posix(EIO) }
    do {
      let snapshot = try await access.snapshot(until: deadline)
      deletionAllowed.withLock { $0 = access.canDelete }
      guard !snapshot.storages.isEmpty else { throw RemoteError.posix(ENODEV) }
      return snapshot
    } catch {
      PackageDiagnostics.failure(error, category: .cameraUSB, operation: .snapshot)
      throw CameraUSBErrorMapper.map(error)
    }
  }

  private struct Node {
    let item: RemoteItem
    let fileHandle: UInt32?
  }

  private func makeIndex(_ snapshot: CameraUSBSnapshot) throws -> [String: Node] {
    var result: [String: Node] = [:]
    let root = try RemotePath("/")
    result[root.value] = Node(
      item: RemoteItem(
        path: root, name: "/", isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0)),
      fileHandle: nil)

    var storageIDs = Set<String>()
    var storageNames = Set<String>()
    var storageRoots: [String: String] = [:]
    for storage in snapshot.storages {
      guard !storage.id.isEmpty, !storage.name.isEmpty,
        storageIDs.insert(storage.id).inserted,
        storageNames.insert(storage.name).inserted
      else {
        throw RemoteError.protocolError
      }
      let path = try RemotePath("/" + storage.name)
      guard path.value == "/" + storage.name else { throw RemoteError.protocolError }
      storageRoots[storage.id] = path.value
      result[path.value] = Node(
        item: RemoteItem(
          path: path, name: storage.name, isDirectory: true, size: 0,
          modified: Date(timeIntervalSince1970: 0)),
        fileHandle: nil)
    }

    var explicitPaths = Set<String>()
    var handles = Set<UInt32>()
    for entry in snapshot.entries {
      guard let root = storageRoots[entry.storageID], !entry.relativePath.isEmpty,
        !entry.relativePath.hasPrefix("/"), entry.size >= 0,
        !entry.isDirectory || entry.fileHandle == nil,
        entry.isDirectory || entry.fileHandle != nil
      else {
        throw RemoteError.protocolError
      }
      let path = try RemotePath(root + "/" + entry.relativePath)
      guard path.value == root + "/" + entry.relativePath else {
        throw RemoteError.protocolError
      }

      guard explicitPaths.insert(path.value).inserted else { throw RemoteError.protocolError }
      if let existing = result[path.value], !existing.item.isDirectory || !entry.isDirectory {
        throw RemoteError.protocolError
      }
      if !entry.isDirectory, let handle = entry.fileHandle {
        guard handle != 0, handles.insert(handle).inserted else { throw RemoteError.protocolError }
      }
      var parent = ""
      for component in path.value.split(separator: "/").dropLast() {
        parent += "/" + component
        if let existing = result[parent], !existing.item.isDirectory {
          throw RemoteError.protocolError
        }
        if result[parent] == nil {
          let parentPath = try RemotePath(parent)
          result[parent] = Node(
            item: RemoteItem(
              path: parentPath,
              name: parentPath.value.split(separator: "/").last.map(String.init) ?? "",
              isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0)),
            fileHandle: nil)
        }
      }

      let name = path.value.split(separator: "/").last.map(String.init) ?? ""
      result[path.value] = Node(
        item: RemoteItem(
          path: path, name: name, isDirectory: entry.isDirectory, size: entry.size,
          modified: entry.modified),
        fileHandle: entry.fileHandle)
    }
    return result
  }
}

private actor CameraUSBReadCursor {
  private let access: any CameraUSBAccess
  private let handle: UInt32
  private var offset: Int64
  private let end: Int64

  init(access: any CameraUSBAccess, handle: UInt32, start: Int64, end: Int64) {
    self.access = access
    self.handle = handle
    offset = start
    self.end = end
  }

  func next() async throws -> Data? {
    try Task.checkCancellation()
    guard offset < end else { return nil }
    let length = Int(min(1_048_576, end - offset))
    do {
      let data = try await access.read(handle: handle, offset: offset, length: length)
      guard !data.isEmpty, data.count <= length else { throw RemoteError.posix(EIO) }
      offset += Int64(data.count)
      return data
    } catch {
      PackageDiagnostics.failure(error, category: .cameraUSB, operation: .download)
      throw error
    }
  }
}
