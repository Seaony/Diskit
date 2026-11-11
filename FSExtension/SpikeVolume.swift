import FSKit
import Foundation

/// 验证用的一个节点：普通文件存内存；`syntheticSize` 不为空的是现算内容的大文件，不占内存。
final class SpikeItem: FSItem, @unchecked Sendable {
  let id: UInt64
  let type: FSItem.ItemType
  var name: FSFileName
  var parentID: UInt64
  var mode: UInt32
  var data = Data()
  var syntheticSize: UInt64?
  var children: [Data: SpikeItem] = [:]
  var xattrs: [Data: Data] = [:]
  var modifyTime = timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0)
  var birthTime = timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0)

  init(id: UInt64, type: FSItem.ItemType, name: FSFileName, parentID: UInt64, mode: UInt32) {
    self.id = id
    self.type = type
    self.name = name
    self.parentID = parentID
    self.mode = mode
  }

  var size: UInt64 { syntheticSize ?? UInt64(data.count) }
}

/// 内存假数据卷：readme.txt、big.bin（1 GiB 现算内容）、Folder/inside.txt。
/// 所有改动都记日志，用来看 Finder 拷文件时会产生哪些操作。
final class SpikeVolume: FSVolume, FSVolume.Operations, FSVolume.OpenCloseOperations, FSVolume.ReadWriteOperations,
  FSVolume.XattrOperations, @unchecked Sendable
{
  private let lock = NSLock()
  private var items: [UInt64: SpikeItem] = [:]
  private var nextID: UInt64 = FSItem.Identifier.rootDirectory.rawValue + 1
  private let root: SpikeItem
  private let uid = getuid()
  private let gid = getgid()

  init(volumeID: FSVolume.Identifier, volumeName: FSFileName, readme: String) {
    root = SpikeItem(
      id: FSItem.Identifier.rootDirectory.rawValue, type: .directory, name: FSFileName(string: "/"),
      parentID: FSItem.Identifier.parentOfRoot.rawValue, mode: UInt32(S_IFDIR | 0o755))
    super.init(volumeID: volumeID, volumeName: volumeName)
    items[root.id] = root
    add(file: "readme.txt", in: root).data = Data(readme.utf8)
    add(file: "big.bin", in: root).syntheticSize = 1 << 30
    let folder = add(directory: "Folder", in: root)
    add(file: "inside.txt", in: folder).data = Data("在文件夹里\n".utf8)
  }

  /// 在根目录放一个文本文件，已有就替换内容。
  func setRootFile(_ name: String, text: String) {
    locked {
      let key = FSFileName(string: name)
      let item = root.children[key.data] ?? add(file: key, in: root)
      item.data = Data(text.utf8)
    }
  }

  // MARK: 卷属性

  var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
    let capabilities = FSVolume.SupportedCapabilities()
    capabilities.supportsPersistentObjectIDs = true
    capabilities.supports64BitObjectIDs = true
    capabilities.supportsFastStatFS = true
    capabilities.supports2TBFiles = true
    capabilities.caseFormat = .sensitive
    return capabilities
  }

  var volumeStatistics: FSStatFSResult {
    let result = FSStatFSResult(fileSystemTypeName: "kayoi")
    result.blockSize = 4096
    result.ioSize = 1 << 20
    result.totalBlocks = (8 << 30) / 4096
    result.availableBlocks = (4 << 30) / 4096
    result.freeBlocks = result.availableBlocks
    result.usedBlocks = result.totalBlocks - result.freeBlocks
    result.totalBytes = 8 << 30
    result.availableBytes = 4 << 30
    result.freeBytes = 4 << 30
    result.usedBytes = 4 << 30
    return result
  }

  var maximumLinkCount: Int { 1 }
  var maximumNameLength: Int { 255 }
  var restrictsOwnershipChanges: Bool { true }
  var truncatesLongNames: Bool { false }
  var maximumXattrSize: Int { 1 << 20 }
  var maximumFileSize: UInt64 { UInt64(Int64.max) }
  var isOpenCloseInhibited = false

  // MARK: 生命周期

  func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, (any Error)?) -> Void) {
    spikeLog.info("activate options=\(options.taskOptions, privacy: .public)")
    replyHandler(root, nil)
  }

  func deactivate(options: FSDeactivateOptions, replyHandler: @escaping ((any Error)?) -> Void) {
    spikeLog.info("deactivate")
    replyHandler(nil)
  }

  func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
    spikeLog.info("mount options=\(options.taskOptions, privacy: .public)")
    replyHandler(nil)
  }

  func unmount(replyHandler: @escaping () -> Void) {
    spikeLog.info("unmount")
    replyHandler()
  }

  func synchronize(flags: FSSyncFlags, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }

  func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }

  // MARK: 查找与列目录

  func lookupItem(
    named name: FSFileName, inDirectory directory: FSItem,
    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let directory = directory as? SpikeItem else { return { replyHandler(nil, nil, POSIXError(.EINVAL)) } }
      guard let item = directory.children[name.data] else {
        spikeLog.info("lookup miss \(Self.text(name), privacy: .public)")
        return { replyHandler(nil, nil, POSIXError(.ENOENT)) }
      }
      let itemName = item.name
      return { replyHandler(item, itemName, nil) }
    }
    reply()
  }

  func enumerateDirectory(
    _ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
    attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
    replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let directory = directory as? SpikeItem, directory.type == .directory else {
        return { replyHandler(FSDirectoryVerifier(0), POSIXError(.ENOTDIR)) }
      }
      // . 和 .. 由系统自己补，这里只列子项；按 ID 排序，cookie 就是下一项的序号
      let entries = directory.children.values.sorted { $0.id < $1.id }
      var index = Int(cookie.rawValue)
      while index < entries.count {
        let item = entries[index]
        let name = item.name
        let packed = packer.packEntry(
          name: name, itemType: item.type, itemID: FSItem.Identifier(item.id),
          nextCookie: FSDirectoryCookie(UInt64(index + 1)), attributes: attributes.map { self.attributes($0, of: item) })
        if !packed { break }
        index += 1
      }
      return { replyHandler(FSDirectoryVerifier(1), nil) }
    }
    reply()
  }

  // MARK: 属性

  func getAttributes(
    _ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
    replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem else { return { replyHandler(nil, POSIXError(.EINVAL)) } }
      let result = attributes(desiredAttributes, of: item)
      return { replyHandler(result, nil) }
    }
    reply()
  }

  func setAttributes(
    _ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
    replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem else { return { replyHandler(nil, POSIXError(.EINVAL)) } }
      if newAttributes.isValid(.size) {
        guard item.syntheticSize == nil else { return { replyHandler(nil, POSIXError(.EROFS)) } }
        let size = Int(newAttributes.size)
        if size < item.data.count { item.data.removeSubrange(size...) } else { item.data.append(Data(count: size - item.data.count)) }
        newAttributes.consumedAttributes.insert(.size)
      }
      if newAttributes.isValid(.mode) {
        item.mode = (item.mode & UInt32(S_IFMT)) | (newAttributes.mode & 0o7777)
        newAttributes.consumedAttributes.insert(.mode)
      }
      if newAttributes.isValid(.modifyTime) {
        item.modifyTime = newAttributes.modifyTime
        newAttributes.consumedAttributes.insert(.modifyTime)
      }
      if newAttributes.isValid(.birthTime) {
        item.birthTime = newAttributes.birthTime
        newAttributes.consumedAttributes.insert(.birthTime)
      }
      spikeLog.info("setattr \(Self.text(item.name), privacy: .public)")
      let result = attributes(Self.allAttributes, of: item)
      return { replyHandler(result, nil) }
    }
    reply()
  }

  // MARK: 新建、删除、改名

  func createItem(
    named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
    attributes newAttributes: FSItem.SetAttributesRequest,
    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let directory = directory as? SpikeItem, directory.type == .directory else {
        return { replyHandler(nil, nil, POSIXError(.ENOTDIR)) }
      }
      guard type == .file || type == .directory else { return { replyHandler(nil, nil, POSIXError(.ENOTSUP)) } }
      guard directory.children[name.data] == nil else { return { replyHandler(nil, nil, POSIXError(.EEXIST)) } }
      spikeLog.info("create \(type == .directory ? "dir" : "file", privacy: .public) \(Self.text(name), privacy: .public)")
      let item = type == .directory ? add(directory: name, in: directory) : add(file: name, in: directory)
      if newAttributes.isValid(.mode) { item.mode = (item.mode & UInt32(S_IFMT)) | (newAttributes.mode & 0o7777) }
      let itemName = item.name
      return { replyHandler(item, itemName, nil) }
    }
    reply()
  }

  func createSymbolicLink(
    named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest,
    linkContents contents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
  ) {
    replyHandler(nil, nil, POSIXError(.ENOTSUP))
  }

  func createLink(
    to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
    replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
  ) {
    replyHandler(nil, POSIXError(.ENOTSUP))
  }

  func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
    replyHandler(nil, POSIXError(.EINVAL))
  }

  func removeItem(
    _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
    replyHandler: @escaping ((any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem, let directory = directory as? SpikeItem else {
        return { replyHandler(POSIXError(.EINVAL)) }
      }
      if item.type == .directory, !item.children.isEmpty { return { replyHandler(POSIXError(.ENOTEMPTY)) } }
      spikeLog.info("remove \(Self.text(name), privacy: .public)")
      directory.children[name.data] = nil
      items[item.id] = nil
      return { replyHandler(nil) }
    }
    reply()
  }

  func renameItem(
    _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName,
    inDirectory destinationDirectory: FSItem, overItem: FSItem?,
    replyHandler: @escaping (FSFileName?, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem, let source = sourceDirectory as? SpikeItem,
        let destination = destinationDirectory as? SpikeItem
      else { return { replyHandler(nil, POSIXError(.EINVAL)) } }
      // 目录不能移进自己或自己的子目录，否则整棵子树就找不到了
      if item.type == .directory {
        var ancestor: SpikeItem? = destination
        while let current = ancestor {
          if current.id == item.id { return { replyHandler(nil, POSIXError(.EINVAL)) } }
          ancestor = current.id == root.id ? nil : items[current.parentID]
        }
      }
      // 覆盖目标时类型要一致，目录只能覆盖空目录
      if let over = overItem as? SpikeItem {
        if over.type == .directory, item.type != .directory { return { replyHandler(nil, POSIXError(.EISDIR)) } }
        if over.type != .directory, item.type == .directory { return { replyHandler(nil, POSIXError(.ENOTDIR)) } }
        if over.type == .directory, !over.children.isEmpty { return { replyHandler(nil, POSIXError(.ENOTEMPTY)) } }
        items[over.id] = nil
      }
      spikeLog.info("rename \(Self.text(sourceName), privacy: .public) -> \(Self.text(destinationName), privacy: .public)")
      source.children[sourceName.data] = nil
      item.name = destinationName
      item.parentID = destination.id
      destination.children[destinationName.data] = item
      return { replyHandler(destinationName, nil) }
    }
    reply()
  }

  // MARK: 打开、读写

  func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
    replyHandler(nil)
  }

  func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
    replyHandler(nil)
  }

  func read(
    from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
    replyHandler: @escaping (Int, (any Error)?) -> Void
  ) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem, item.type == .file else { return { replyHandler(0, POSIXError(.EISDIR)) } }
      let size = item.size
      guard offset >= 0, UInt64(offset) < size else { return { replyHandler(0, nil) } }
      let count = Int(min(UInt64(length), size - UInt64(offset), UInt64(buffer.length)))
      buffer.withUnsafeMutableBytes { bytes in
        if item.syntheticSize != nil {
          // 现算内容：每个字节等于它所在位置的低 8 位，方便核对；从预先算好的花样里整块拷贝
          var done = 0
          while done < count {
            let start = (Int(offset) + done) & 0xFF
            let chunk = min(count - done, Self.pattern.count - start)
            Self.pattern.withUnsafeBytes { source in
              (bytes.baseAddress! + done).copyMemory(from: source.baseAddress! + start, byteCount: chunk)
            }
            done += chunk
          }
        } else {
          item.data.copyBytes(to: bytes.bindMemory(to: UInt8.self), from: Int(offset)..<Int(offset) + count)
        }
      }
      return { replyHandler(count, nil) }
    }
    reply()
  }

  func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, (any Error)?) -> Void) {
    let reply: () -> Void = locked {
      guard let item = item as? SpikeItem, item.type == .file else { return { replyHandler(0, POSIXError(.EISDIR)) } }
      guard item.syntheticSize == nil else { return { replyHandler(0, POSIXError(.EROFS)) } }
      let end = Int(offset) + contents.count
      if item.data.count < end { item.data.append(Data(count: end - item.data.count)) }
      item.data.replaceSubrange(Int(offset)..<end, with: contents)
      item.modifyTime = timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0)
      spikeLog.debug("write \(Self.text(item.name), privacy: .public) \(contents.count) @\(offset)")
      let written = contents.count
      return { replyHandler(written, nil) }
    }
    reply()
  }

  // MARK: 扩展属性（存内存，验证支持后 Finder 是否还生成 ._ 文件）

  func getXattr(named name: FSFileName, of item: FSItem, replyHandler: @escaping (Data?, (any Error)?) -> Void) {
    let value = locked { (item as? SpikeItem)?.xattrs[name.data] }
    replyHandler(value, value == nil ? POSIXError(.ENOATTR) : nil)
  }

  func setXattr(
    named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy,
    replyHandler: @escaping ((any Error)?) -> Void
  ) {
    let error: POSIXError? = locked {
      guard let item = item as? SpikeItem else { return POSIXError(.EINVAL) }
      let exists = item.xattrs[name.data] != nil
      switch policy {
      case .mustCreate where exists: return POSIXError(.EEXIST)
      case .mustReplace where !exists, .delete where !exists: return POSIXError(.ENOATTR)
      case .delete: item.xattrs[name.data] = nil
      default: item.xattrs[name.data] = value ?? Data()
      }
      spikeLog.info("setxattr \(Self.text(item.name), privacy: .public) \(Self.text(name), privacy: .public)")
      return nil
    }
    replyHandler(error)
  }

  func listXattrs(of item: FSItem, replyHandler: @escaping @Sendable ([FSFileName]?, (any Error)?) -> Void) {
    let names = locked { (item as? SpikeItem)?.xattrs.keys.map { FSFileName(data: $0) } ?? [] }
    replyHandler(names, nil)
  }

  // MARK: 内部

  /// 1 MiB 再多 256 字节的 0…255 循环花样，任意偏移都能整块拷出来
  private static let pattern: [UInt8] = (0..<(1 << 20) + 256).map { UInt8(truncatingIfNeeded: $0) }

  private static var allAttributes: FSItem.GetAttributesRequest {
    let request = FSItem.GetAttributesRequest()
    request.wantedAttributes = [
      .type, .mode, .linkCount, .uid, .gid, .flags, .size, .allocSize, .fileID, .parentID, .modifyTime, .changeTime,
      .accessTime, .birthTime,
    ]
    return request
  }

  private func attributes(_ request: FSItem.GetAttributesRequest, of item: SpikeItem) -> FSItem.Attributes {
    let attributes = FSItem.Attributes()
    if request.isAttributeWanted(.type) { attributes.type = item.type }
    if request.isAttributeWanted(.mode) { attributes.mode = item.mode }
    if request.isAttributeWanted(.linkCount) { attributes.linkCount = item.type == .directory ? 2 : 1 }
    if request.isAttributeWanted(.uid) { attributes.uid = uid }
    if request.isAttributeWanted(.gid) { attributes.gid = gid }
    if request.isAttributeWanted(.flags) { attributes.flags = 0 }
    if request.isAttributeWanted(.size) { attributes.size = item.size }
    if request.isAttributeWanted(.allocSize) { attributes.allocSize = item.size }
    if request.isAttributeWanted(.fileID) { attributes.fileID = FSItem.Identifier(item.id) }
    if request.isAttributeWanted(.parentID) { attributes.parentID = FSItem.Identifier(item.parentID) }
    if request.isAttributeWanted(.modifyTime) { attributes.modifyTime = item.modifyTime }
    if request.isAttributeWanted(.changeTime) { attributes.changeTime = item.modifyTime }
    if request.isAttributeWanted(.accessTime) { attributes.accessTime = item.modifyTime }
    if request.isAttributeWanted(.birthTime) { attributes.birthTime = item.birthTime }
    return attributes
  }

  @discardableResult
  private func add(file name: String, in directory: SpikeItem) -> SpikeItem {
    add(file: FSFileName(string: name), in: directory)
  }

  @discardableResult
  private func add(file name: FSFileName, in directory: SpikeItem) -> SpikeItem {
    insert(SpikeItem(id: takeID(), type: .file, name: name, parentID: directory.id, mode: UInt32(S_IFREG | 0o644)), into: directory)
  }

  private func add(directory name: String, in parent: SpikeItem) -> SpikeItem {
    add(directory: FSFileName(string: name), in: parent)
  }

  private func add(directory name: FSFileName, in parent: SpikeItem) -> SpikeItem {
    insert(SpikeItem(id: takeID(), type: .directory, name: name, parentID: parent.id, mode: UInt32(S_IFDIR | 0o755)), into: parent)
  }

  private func insert(_ item: SpikeItem, into directory: SpikeItem) -> SpikeItem {
    items[item.id] = item
    directory.children[item.name.data] = item
    return item
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func takeID() -> UInt64 {
    defer { nextID += 1 }
    return nextID
  }

  private static func text(_ name: FSFileName) -> String { name.string ?? name.debugDescription }
}
