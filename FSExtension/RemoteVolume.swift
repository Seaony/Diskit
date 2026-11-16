import Core
import FSKit
import Foundation
import OSLog

final class DiskitRemoteItem: FSItem, @unchecked Sendable {
  let id: UInt64
  var remote: RemoteItem
  var parentID: UInt64
  var mode: UInt32
  var flags: UInt32 = 0
  var modifyTime: timespec
  var accessTime: timespec
  var birthTime: timespec

  init(id: UInt64, remote: RemoteItem, parentID: UInt64, writable: Bool) {
    self.id = id
    self.remote = remote
    self.parentID = parentID
    let writable = writable || LocalMetadataOverlay.handles(remote.path)
    mode = UInt32(remote.isDirectory ? S_IFDIR : S_IFREG)
      | UInt32(remote.isDirectory ? (writable ? 0o755 : 0o555) : (writable ? 0o644 : 0o444))
    let time = Self.time(remote.modified)
    modifyTime = time
    accessTime = time
    birthTime = time
  }

  static func time(_ date: Date) -> timespec {
    let seconds = date.timeIntervalSince1970
    let whole = floor(seconds)
    return timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))
  }

  static func date(_ time: timespec) -> Date {
    Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
  }
}

final class DiskitRemoteVolume: FSVolume, FSVolume.Operations, FSVolume.OpenCloseOperations,
  FSVolume.ReadWriteOperations, FSVolume.XattrOperations, @unchecked Sendable
{
  private let backend: RemoteVolumeBackend
  private let connection: Connection
  private let connectionID: String
  private let space: SpaceInfo
  private let lock = NSLock()
  private var items: [RemotePath: DiskitRemoteItem] = [:]
  private var nextID = FSItem.Identifier.rootDirectory.rawValue + 1
  private let root: DiskitRemoteItem
  private let uid = getuid()
  private let gid = getgid()
  private let lifecycleLog = Logger(subsystem: "com.seaony.Diskit.FS", category: "VolumeLifecycle")
  private let operationLog = Logger(subsystem: "com.seaony.Diskit.FS", category: "VolumeOperation")
  private let transferLog = Logger(subsystem: "com.seaony.Diskit.FS", category: "VolumeTransfer")

  init(connection: Connection, backend: RemoteVolumeBackend, space: SpaceInfo) {
    self.backend = backend
    self.connection = connection
    self.space = space
    connectionID = connection.id.uuidString
    let path = try! RemotePath("/")
    root = DiskitRemoteItem(
      id: FSItem.Identifier.rootDirectory.rawValue,
      remote: RemoteItem(path: path, name: "/", isDirectory: true, size: 0,
                         modified: Date(timeIntervalSince1970: 0)),
      parentID: FSItem.Identifier.parentOfRoot.rawValue,
      writable: Self.writable(remoteIsDirectory: true, capabilities: backend.capabilities))
    super.init(volumeID: FSVolume.Identifier(uuid: connection.id), volumeName: FSFileName(string: connection.name))
    items[path] = root
  }

  var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
    let capabilities = FSVolume.SupportedCapabilities()
    capabilities.supports64BitObjectIDs = true
    capabilities.caseFormat = .sensitive
    return capabilities
  }

  var volumeStatistics: FSStatFSResult {
    let result = FSStatFSResult(fileSystemTypeName: "diskit")
    result.blockSize = 4096
    result.ioSize = 1 << 20
    result.totalBytes = UInt64(space.total ?? 0)
    result.usedBytes = UInt64(space.used ?? 0)
    result.availableBytes = UInt64(space.available ?? 0)
    result.freeBytes = result.availableBytes
    result.totalBlocks = result.totalBytes / 4096
    result.usedBlocks = result.usedBytes / 4096
    result.availableBlocks = result.availableBytes / 4096
    result.freeBlocks = result.availableBlocks
    return result
  }

  var maximumLinkCount: Int { 1 }
  var maximumNameLength: Int { 255 }
  var restrictsOwnershipChanges: Bool { true }
  var truncatesLongNames: Bool { false }
  var maximumXattrSize: Int { 1 << 20 }
  var maximumFileSize: UInt64 { UInt64(Int64.max) }
  var isOpenCloseInhibited = false

  func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, Error?) -> Void) {
    lifecycleLog.info("connection=\(self.connectionID, privacy: .public) activate")
    replyHandler(root, nil)
  }

  func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
    lifecycleLog.info("connection=\(self.connectionID, privacy: .public) mount")
    replyHandler(nil)
  }

  func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) {
    perform("synchronize", body: { try await self.backend.flushAll() }) { replyHandler($0.failure) }
  }

  func unmount(replyHandler: @escaping () -> Void) {
    perform("unmount", body: {
      defer { self.lifecycleLog.info("connection=\(self.connectionID, privacy: .public) unmount") }
      do {
        try await self.backend.flushAll()
        await self.backend.disconnect()
      } catch {
        await self.backend.disconnect()
        throw error
      }
    }) { _ in replyHandler() }
  }

  func deactivate(options: FSDeactivateOptions, replyHandler: @escaping (Error?) -> Void) {
    lifecycleLog.info("connection=\(self.connectionID, privacy: .public) deactivate")
    replyHandler(nil)
  }

  func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
    replyHandler(nil)
  }

  func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                  replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
    perform("lookup", item: directory, suffix: name.string ?? "", body: {
      let parent = try self.directory(directory)
      let path = self.path(of: parent)
      let entries = try await self.backend.list(path)
      let matches = RemoteVolumeBackend.entries(named: name.data, in: entries)
      guard matches.count <= 1 else { throw POSIXError(.EEXIST) }
      guard let found = matches.first else { throw POSIXError(.ENOENT) }
      let node = self.node(for: found, parentID: parent.id)
      return (node, FSFileName(string: found.path.basename))
    }) { result in
      switch result {
      case .success(let value): replyHandler(value.0, value.1, nil)
      case .failure(let error): replyHandler(nil, nil, error)
      }
    }
  }

  func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                          verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?,
                          packer: FSDirectoryEntryPacker,
                          replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
    perform("list", item: directory, body: {
      let parent = try self.directory(directory)
      let entries = try await self.backend.list(self.path(of: parent))
        .filter { !$0.path.basename.isEmpty && $0.path.basename != "." && $0.path.basename != ".." }
        .sorted { $0.path.basename.utf8.lexicographicallyPrecedes($1.path.basename.utf8) }
      guard cookie.rawValue <= UInt64(entries.count) else { throw POSIXError(.EINVAL) }
      var names = Set<Data>()
      for entry in entries {
        guard names.insert(FSFileName(string: entry.path.basename).data).inserted else {
          throw POSIXError(.EEXIST)
        }
      }
      for index in Int(cookie.rawValue)..<entries.count {
        let entry = entries[index]
        let node = self.node(for: entry, parentID: parent.id)
        let values = attributes.map { request in self.locked { self.attributes(request, of: node) } }
        if !packer.packEntry(name: FSFileName(string: entry.path.basename),
                             itemType: entry.isDirectory ? .directory : .file,
                             itemID: FSItem.Identifier(node.id),
                             nextCookie: FSDirectoryCookie(UInt64(index + 1)), attributes: values) { break }
      }
    }) { replyHandler(FSDirectoryVerifier(1), $0.failure) }
  }

  func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                     replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
    perform("getattr", item: item, body: {
      let node = try self.item(item)
      let remote = try await self.backend.attributes(self.path(of: node))
      let updated = self.node(for: remote, parentID: self.locked { node.parentID })
      return self.locked { self.attributes(desiredAttributes, of: updated) }
    }) { result in replyHandler(try? result.get(), result.failure) }
  }

  func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                     replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
    perform("setattr", item: item, body: {
      let node = try self.item(item)
      let path = self.path(of: node)
      guard self.backend.capabilities.canWrite || LocalMetadataOverlay.handles(path) else {
        throw POSIXError(.EROFS)
      }
      if newAttributes.isValid(.size), !self.locked({ node.remote.isDirectory }) {
        guard newAttributes.size <= UInt64(Int64.max) else { throw POSIXError(.EFBIG) }
        try await self.backend.resize(path, size: Int64(newAttributes.size))
      }
      if newAttributes.isValid(.modifyTime), !self.locked({ node.remote.isDirectory }) {
        try await self.backend.setModifiedDate(path, date: DiskitRemoteItem.date(newAttributes.modifyTime))
      }
      return self.locked {
        self.apply(newAttributes, to: node)
        return self.attributes(Self.allAttributes, of: node)
      }
    }) { result in replyHandler(try? result.get(), result.failure) }
  }

  func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                  attributes newAttributes: FSItem.SetAttributesRequest,
                  replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
    perform("create", item: directory, suffix: name.string ?? "", body: {
      guard type == .file || type == .directory else { throw POSIXError(.ENOTSUP) }
      let parent = try self.directory(directory)
      let component = try Self.component(name)
      let path = try self.path(of: parent).appending(component)
      let remote = try await (type == .directory
        ? self.backend.makeDirectory(path) : self.backend.createFile(path))
      let node = self.node(for: remote, parentID: parent.id)
      if type == .file, newAttributes.isValid(.size), newAttributes.size > 0 {
        guard newAttributes.size <= UInt64(Int64.max) else { throw POSIXError(.EFBIG) }
        try await self.backend.resize(remote.path, size: Int64(newAttributes.size))
      }
      if type == .file, newAttributes.isValid(.modifyTime) {
        try await self.backend.setModifiedDate(remote.path, date: DiskitRemoteItem.date(newAttributes.modifyTime))
      }
      self.locked { self.apply(newAttributes, to: node) }
      return (node, FSFileName(string: remote.path.basename))
    }) { result in
      switch result {
      case .success(let value): replyHandler(value.0, value.1, nil)
      case .failure(let error): replyHandler(nil, nil, error)
      }
    }
  }

  func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                  replyHandler: @escaping (Error?) -> Void) {
    perform("remove", item: item, body: {
      let node = try self.item(item)
      let path = self.path(of: node)
      guard path.value != "/" else { throw POSIXError(.EBUSY) }
      if self.locked({ node.remote.isDirectory }), !(try await self.backend.list(path)).isEmpty {
        throw POSIXError(.ENOTEMPTY)
      }
      try await self.backend.remove(path, recursive: false)
      self.locked { self.items[path] = nil }
    }) { replyHandler($0.failure) }
  }

  func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                  to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                  overItem: FSItem?, replyHandler: @escaping (FSFileName?, Error?) -> Void) {
    perform("rename", item: item, body: {
      let node = try self.item(item)
      let parent = try self.directory(destinationDirectory)
      let source = self.path(of: node)
      let destination = try self.path(of: parent).appending(Self.component(destinationName))
      guard source.value != "/" else { throw POSIXError(.EBUSY) }
      if source == destination { return destinationName }
      if self.locked({ node.remote.isDirectory }), destination.value.hasPrefix(source.value + "/") {
        throw POSIXError(.EINVAL)
      }
      if let overItem {
        let target = try self.item(overItem)
        let sourceIsDirectory = self.locked { node.remote.isDirectory }
        let targetIsDirectory = self.locked { target.remote.isDirectory }
        guard sourceIsDirectory == targetIsDirectory else {
          throw POSIXError(targetIsDirectory ? .EISDIR : .ENOTDIR)
        }
        if targetIsDirectory, !(try await self.backend.list(self.path(of: target))).isEmpty {
          throw POSIXError(.ENOTEMPTY)
        }
      }
      self.operationLog.info("connection=\(self.connectionID, privacy: .public) rename source=\(source.value, privacy: .public) destination=\(destination.value, privacy: .public) replacing=\(overItem != nil)")
      try await self.backend.move(source, to: destination, replacing: overItem != nil)
      self.locked {
        let moved = self.items.values.filter {
          $0.remote.path == source || $0.remote.path.value.hasPrefix(source.value + "/")
        }
        self.items[destination] = nil
        for child in moved { self.items[child.remote.path] = nil }
        for child in moved {
          let suffix = child.remote.path.value.dropFirst(source.value.count)
          child.remote.path = try! RemotePath(destination.value + suffix)
          if child === node {
            child.remote.name = destinationName.string ?? destination.basename
            child.parentID = parent.id
          }
          self.items[child.remote.path] = child
        }
      }
      return destinationName
    }) { result in replyHandler(try? result.get(), result.failure) }
  }

  func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping (Error?) -> Void) {
    perform("open", item: item, body: {
      let node = try self.item(item)
      if !self.locked({ node.remote.isDirectory }) {
        try await self.backend.open(self.path(of: node), writable: modes.contains(.write))
      }
    }) { replyHandler($0.failure) }
  }

  func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping (Error?) -> Void) {
    perform("close", item: item, body: {
      let node = try self.item(item)
      guard !self.locked({ node.remote.isDirectory }) else { return }
      let path = self.path(of: node)
      if modes.isEmpty { try await self.backend.close(path) }
      else if !modes.contains(.write) { try await self.backend.flush(path) }
    }) { replyHandler($0.failure) }
  }

  func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
             replyHandler: @escaping (Int, Error?) -> Void) {
    perform("read", item: item, offset: offset, body: {
      let node = try self.file(item)
      guard offset >= 0, length >= 0 else { throw POSIXError(.EINVAL) }
      let capacity = min(length, Int(buffer.length))
      let data = try await self.backend.read(self.path(of: node), offset: offset, length: capacity)
      guard data.count <= capacity else { throw POSIXError(.EIO) }
      _ = buffer.withUnsafeMutableBytes { bytes in data.copyBytes(to: bytes.bindMemory(to: UInt8.self)) }
      return data.count
    }) { result in replyHandler((try? result.get()) ?? 0, result.failure) }
  }

  func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler: @escaping (Int, Error?) -> Void) {
    perform("write", item: item, offset: offset, body: {
      let node = try self.file(item)
      let count = try await self.backend.write(self.path(of: node), offset: offset, data: contents)
      self.locked {
        node.remote.size = max(node.remote.size, Int64(offset) + Int64(count))
        node.remote.modified = Date()
        node.modifyTime = DiskitRemoteItem.time(node.remote.modified)
      }
      return count
    }) { result in replyHandler((try? result.get()) ?? 0, result.failure) }
  }

  func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                          attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
                          replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
    replyHandler(nil, nil, POSIXError(.ENOTSUP))
  }

  func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                  replyHandler: @escaping (FSFileName?, Error?) -> Void) {
    replyHandler(nil, POSIXError(.ENOTSUP))
  }

  func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, Error?) -> Void) {
    replyHandler(nil, POSIXError(.ENOTSUP))
  }

  func getXattr(named name: FSFileName, of item: FSItem,
                replyHandler: @escaping (Data?, Error?) -> Void) {
    perform("getxattr", item: item, body: {
      let node = try self.item(item)
      return try await self.backend.getXattr(named: name.data, of: self.path(of: node))
    }) { result in replyHandler(try? result.get(), result.failure) }
  }

  func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                policy: FSVolume.SetXattrPolicy, replyHandler: @escaping (Error?) -> Void) {
    perform("setxattr", item: item, body: {
      let node = try self.item(item)
      let remotePolicy: RemoteXattrPolicy
      switch policy {
      case .alwaysSet: remotePolicy = .set
      case .mustCreate: remotePolicy = .create
      case .mustReplace: remotePolicy = .replace
      case .delete: remotePolicy = .remove
      @unknown default: throw POSIXError(.EINVAL)
      }
      try await self.backend.setXattr(named: name.data, to: value, on: self.path(of: node),
                                      policy: remotePolicy)
    }) { replyHandler($0.failure) }
  }

  func listXattrs(of item: FSItem, replyHandler: @escaping @Sendable ([FSFileName]?, Error?) -> Void) {
    perform("listxattrs", item: item, body: {
      let node = try self.item(item)
      let names = try await self.backend.listXattrs(of: self.path(of: node))
      return names.map { FSFileName(data: $0) }
    }) { result in replyHandler(try? result.get(), result.failure) }
  }

  private func item(_ item: FSItem) throws -> DiskitRemoteItem {
    guard let node = item as? DiskitRemoteItem else { throw POSIXError(.EINVAL) }
    return node
  }

  private func directory(_ item: FSItem) throws -> DiskitRemoteItem {
    let node = try self.item(item)
    guard locked({ node.remote.isDirectory }) else { throw POSIXError(.ENOTDIR) }
    return node
  }

  private func file(_ item: FSItem) throws -> DiskitRemoteItem {
    let node = try self.item(item)
    guard !locked({ node.remote.isDirectory }) else { throw POSIXError(.EISDIR) }
    return node
  }

  private func path(of item: DiskitRemoteItem) -> RemotePath { locked { item.remote.path } }

  private func node(for remote: RemoteItem, parentID: UInt64) -> DiskitRemoteItem {
    locked {
      if let existing = items[remote.path] {
        if existing.remote.modified != remote.modified {
          existing.modifyTime = DiskitRemoteItem.time(remote.modified)
        }
        existing.remote = remote
        existing.parentID = parentID
        return existing
      }
      let node = DiskitRemoteItem(id: nextID, remote: remote, parentID: parentID,
                                writable: Self.writable(remoteIsDirectory: remote.isDirectory,
                                                        capabilities: backend.capabilities))
      nextID += 1
      items[remote.path] = node
      return node
    }
  }

  private static func writable(remoteIsDirectory: Bool, capabilities: ProviderCapabilities) -> Bool {
    // 只读但能删除的设备也需要目录写权限；实际操作仍按各项能力拦截。
    capabilities.canWrite || (remoteIsDirectory
      && (capabilities.canDelete || capabilities.canRename || capabilities.canMove))
  }

  private func apply(_ request: FSItem.SetAttributesRequest, to item: DiskitRemoteItem) {
    if request.isValid(.size), !item.remote.isDirectory {
      item.remote.size = Int64(request.size)
      request.consumedAttributes.insert(.size)
    }
    if request.isValid(.mode) {
      item.mode = (item.mode & UInt32(S_IFMT)) | (request.mode & 0o7777)
      request.consumedAttributes.insert(.mode)
    }
    if request.isValid(.flags) {
      item.flags = request.flags
      request.consumedAttributes.insert(.flags)
    }
    if request.isValid(.modifyTime) {
      item.modifyTime = request.modifyTime
      request.consumedAttributes.insert(.modifyTime)
    }
    if request.isValid(.accessTime) {
      item.accessTime = request.accessTime
      request.consumedAttributes.insert(.accessTime)
    }
    if request.isValid(.birthTime) {
      item.birthTime = request.birthTime
      request.consumedAttributes.insert(.birthTime)
    }
  }

  private static func component(_ name: FSFileName) throws -> String {
    guard let name = name.string, !name.isEmpty, name.utf8.count <= 255,
          !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
      throw POSIXError(.EINVAL)
    }
    return name
  }

  private static var allAttributes: FSItem.GetAttributesRequest {
    let request = FSItem.GetAttributesRequest()
    request.wantedAttributes = [.type, .mode, .linkCount, .uid, .gid, .flags, .size, .allocSize,
                                .fileID, .parentID, .modifyTime, .changeTime, .accessTime, .birthTime]
    return request
  }

  private func attributes(_ request: FSItem.GetAttributesRequest, of item: DiskitRemoteItem) -> FSItem.Attributes {
    let result = FSItem.Attributes()
    if request.isAttributeWanted(.type) { result.type = item.remote.isDirectory ? .directory : .file }
    if request.isAttributeWanted(.mode) { result.mode = item.mode }
    if request.isAttributeWanted(.linkCount) { result.linkCount = item.remote.isDirectory ? 2 : 1 }
    if request.isAttributeWanted(.uid) { result.uid = uid }
    if request.isAttributeWanted(.gid) { result.gid = gid }
    if request.isAttributeWanted(.flags) { result.flags = item.flags }
    if request.isAttributeWanted(.size) { result.size = UInt64(max(0, item.remote.size)) }
    if request.isAttributeWanted(.allocSize) { result.allocSize = UInt64(max(0, item.remote.size)) }
    if request.isAttributeWanted(.fileID) { result.fileID = FSItem.Identifier(item.id) }
    if request.isAttributeWanted(.parentID) { result.parentID = FSItem.Identifier(item.parentID) }
    if request.isAttributeWanted(.modifyTime) { result.modifyTime = item.modifyTime }
    if request.isAttributeWanted(.changeTime) { result.changeTime = item.modifyTime }
    if request.isAttributeWanted(.accessTime) { result.accessTime = item.accessTime }
    if request.isAttributeWanted(.birthTime) { result.birthTime = item.birthTime }
    return result
  }

  private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func perform<Value>(_ operation: String, item: FSItem? = nil, suffix: String = "", offset: Int64 = 0,
                              body: @escaping () async throws -> Value,
                              completion: @escaping (Result<Value, Error>) -> Void) {
    let call = VolumeCall(body: body, completion: completion)
    let base = (item as? DiskitRemoteItem).map { path(of: $0).value } ?? "/"
    let path = suffix.isEmpty ? base : (base == "/" ? "" : base) + "/" + suffix
    Task {
      do {
        let value = try await call.body()
        let logger = operation == "read" || operation == "write" ? self.transferLog : self.operationLog
        logger.debug("connection=\(self.connectionID, privacy: .public) operation=\(operation, privacy: .public) path=\(path, privacy: .public) offset=\(offset) success")
        call.completion(.success(value))
      } catch {
        FileSystemLoginEvent.postIfNeeded(error, connection: self.connection)
        let failure = error as NSError
        let errno: Int
        if (error as? any LoginRequiredFailure)?.requiresLogin == true {
          errno = Int(EACCES)
        } else {
          errno = failure.domain == NSPOSIXErrorDomain ? failure.code : Int(EIO)
        }
        self.operationLog.error("connection=\(self.connectionID, privacy: .public) operation=\(operation, privacy: .public) path=\(path, privacy: .public) offset=\(offset) errno=\(errno) error=\(failure.localizedDescription, privacy: .public)")
        call.completion(.failure(POSIXError(POSIXErrorCode(rawValue: Int32(errno)) ?? .EIO)))
      }
    }
  }
}

// 请求和回调由同一个任务持有，回调始终在释放节点锁之后执行。
private struct VolumeCall<Value>: @unchecked Sendable {
  let body: () async throws -> Value
  let completion: (Result<Value, Error>) -> Void
}

private extension Result where Failure == Error {
  var failure: Error? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
