import Core
import Foundation
import IOKit
import Testing

@testable import ADB

// 内存里的 MTP 设备：按 USB 批量传输的规矩收发（一次传输读不完就分几次读；数据正好是包长整数倍时补零长度包）
actor FakeMTPDevice: MTPChannel {
  struct Object {
    var storage: UInt32
    var parent: UInt32  // 0 表示存储根目录
    var name: String
    var isDirectory: Bool
    var data: Data
    var modified = "20251126T093000"
  }
  nonisolated let packetSize = 512
  var storages: [UInt32: String]
  var objects: [UInt32: Object] = [:]
  var nextHandle: UInt32 = 100
  var sendsZLP = true
  var operations: Set<UInt16> = [
    0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B, 0x100C, 0x100D,
    0x1019, 0x101B, 0x9803, 0x9804, 0x95C1,
  ]
  var sessionOpen = false
  func closeSessionOnDevice() { sessionOpen = false }
  var log: [UInt16] = []
  var cancels = 0
  private var incoming = Data()
  private var outgoing: [Data] = []
  private var pendingCommand: (code: UInt16, transaction: UInt32, params: [UInt32])?
  private var pendingSendObject: (handle: UInt32, size: Int)?

  init(storages: [UInt32: String] = [0x10001: "内部共享存储空间"]) { self.storages = storages }

  func setOperations(_ value: Set<UInt16>) { operations = value }
  func setSendsZLP(_ value: Bool) { sendsZLP = value }
  func setStorages(_ value: [UInt32: String]) { storages = value }
  // 模拟设备睡眠、锁屏：接下来这么多次写入都不收，写入超时
  var ignoredWrites = 0
  func ignoreWrites(_ count: Int) { ignoredWrites = count }
  @discardableResult
  func add(_ name: String, parent: UInt32 = 0, storage: UInt32 = 0x10001, data: Data? = nil)
    -> UInt32
  {
    let handle = nextHandle
    nextHandle += 1
    objects[handle] = Object(
      storage: storage, parent: parent, name: name, isDirectory: data == nil, data: data ?? Data())
    return handle
  }
  func child(_ name: String, of parent: UInt32 = 0) -> Object? {
    objects.values.first { $0.parent == parent && $0.name == name }
  }
  func handle(_ name: String, of parent: UInt32 = 0) -> UInt32? {
    objects.first { $0.value.parent == parent && $0.value.name == name }?.key
  }
  // 在设备上直接改名，句柄不变（Android 就是这样）
  func renameOnDevice(_ handle: UInt32, to name: String) { objects[handle]?.name = name }
  func names(in parent: UInt32 = 0) -> [String] {
    objects.values.filter { $0.parent == parent }.map(\.name).sorted()
  }

  // MARK: USBChannel

  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !outgoing.isEmpty else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(kIOReturnTimeout))
    }
    let front = outgoing.removeFirst()
    if front.count > count {
      outgoing.insert(front.subdata(in: count..<front.count), at: 0)
      return front.prefix(count)
    }
    // 没有零长度包时，短包后面紧跟的响应会和数据并到同一次传输里
    if !sendsZLP, front.count % packetSize == 0, !front.isEmpty, let next = outgoing.first,
      front.count + next.count <= count
    {
      outgoing.removeFirst()
      return front + next
    }
    return front
  }

  func write(_ data: Data, timeout: TimeInterval) async throws -> Int {
    if ignoredWrites > 0 {
      ignoredWrites -= 1
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(kIOReturnTimeout))
    }
    incoming.append(data)
    try process()
    return data.count
  }

  func close() async {}
  func cancel(transactionID: UInt32) async { cancels += 1 }

  // MARK: 设备端

  private func process() throws {
    while incoming.count >= 12 {
      var reader = MTPReader(incoming)
      let length = Int(try reader.u32())
      let type = try reader.u16()
      let code = try reader.u16()
      let transaction = try reader.u32()
      guard incoming.count >= length else { return }
      let bytes = Array(incoming)
      let body = Data(bytes[12..<length])
      incoming = Data(bytes[length...])
      if type == 1 {
        var params: [UInt32] = []
        var p = MTPReader(body)
        while p.remaining >= 4 { params.append(try p.u32()) }
        log.append(code)
        if [0x100C, 0x100D, 0x9804].contains(code) {
          pendingCommand = (code, transaction, params)
        } else {
          handle(code, transaction, params, data: nil)
        }
      } else if type == 2, let command = pendingCommand {
        pendingCommand = nil
        handle(command.code, command.transaction, command.params, data: body)
      }
    }
  }

  private func respond(_ code: UInt16, _ transaction: UInt32, _ params: [UInt32] = [], data: Data? = nil, operation: UInt16 = 0) {
    if let data {
      var container = Data()
      container.appendMTP(UInt32(12 + data.count))
      container.appendMTP(UInt16(2))
      container.appendMTP(operation)
      container.appendMTP(transaction)
      container.append(data)
      outgoing.append(container)
      if container.count % packetSize == 0, sendsZLP { outgoing.append(Data()) }
    }
    var response = Data()
    response.appendMTP(UInt32(12 + params.count * 4))
    response.appendMTP(UInt16(3))
    response.appendMTP(code)
    response.appendMTP(transaction)
    for param in params { response.appendMTP(param) }
    outgoing.append(response)
  }

  private func string(_ value: String) -> Data {
    var data = Data()
    try? data.appendMTP(string: value)
    return data
  }

  private func handle(_ code: UInt16, _ tid: UInt32, _ params: [UInt32], data: Data?) {
    guard operations.contains(code) else { return respond(0x2005, tid) }
    if !sessionOpen, code != 0x1001, code != 0x1002 { return respond(0x2003, tid) }
    switch code {
    case 0x1001:
      var info = Data()
      info.appendMTP(UInt16(100))
      info.appendMTP(UInt32(6))
      info.appendMTP(UInt16(100))
      info.append(string("microsoft.com: 1.0; android.com: 1.0;"))
      info.appendMTP(UInt16(0))
      info.appendMTP(UInt32(operations.count))
      for op in operations.sorted() { info.appendMTP(op) }
      for _ in 0..<4 { info.appendMTP(UInt32(0)) }
      info.append(string("ONYX"))
      info.append(string("Leaf5"))
      info.append(string("1.0"))
      info.append(string("1058481e"))
      respond(0x2001, tid, data: info, operation: code)
    case 0x1002:
      if sessionOpen { return respond(0x201E, tid) }
      sessionOpen = true
      respond(0x2001, tid)
    case 0x1003:
      sessionOpen = false
      respond(0x2001, tid)
    case 0x1004:
      var ids = Data()
      ids.appendMTP(UInt32(storages.count))
      for id in storages.keys.sorted() { ids.appendMTP(id) }
      respond(0x2001, tid, data: ids, operation: code)
    case 0x1005:
      guard let name = storages[params[0]] else { return respond(0x2008, tid) }
      var info = Data()
      info.appendMTP(UInt16(3))
      info.appendMTP(UInt16(2))
      info.appendMTP(UInt16(0))
      info.appendMTP(UInt64(64_000_000_000))
      info.appendMTP(UInt64(20_000_000_000))
      info.appendMTP(UInt32(0))
      info.append(string(name))
      info.append(string(""))
      respond(0x2001, tid, data: info, operation: code)
    case 0x1007:
      let parent = params[2] == 0xFFFF_FFFF ? 0 : params[2]
      let handles = objects.filter { $0.value.storage == params[0] && $0.value.parent == parent }
        .keys.sorted()
      var list = Data()
      list.appendMTP(UInt32(handles.count))
      for handle in handles { list.appendMTP(handle) }
      respond(0x2001, tid, data: list, operation: code)
    case 0x1008:
      guard let object = objects[params[0]] else { return respond(0x2009, tid) }
      var info = Data()
      info.appendMTP(object.storage)
      info.appendMTP(object.isDirectory ? UInt16(0x3001) : UInt16(0x3000))
      info.appendMTP(UInt16(0))
      info.appendMTP(UInt32(object.data.count))
      info.appendMTP(UInt16(0))
      for _ in 0..<6 { info.appendMTP(UInt32(0)) }
      info.appendMTP(object.parent)
      info.appendMTP(UInt16(object.isDirectory ? 1 : 0))
      info.appendMTP(UInt32(0))
      info.appendMTP(UInt32(0))
      info.append(string(object.name))
      info.append(string(""))
      info.append(string(object.modified))
      info.append(string(""))
      respond(0x2001, tid, data: info, operation: code)
    case 0x1009:
      guard let object = objects[params[0]] else { return respond(0x2009, tid) }
      respond(0x2001, tid, data: object.data, operation: code)
    case 0x101B, 0x95C1:
      guard let object = objects[params[0]] else { return respond(0x2009, tid) }
      let offset = code == 0x95C1 ? Int(params[1]) | Int(params[2]) << 32 : Int(params[1])
      let count = Int(code == 0x95C1 ? params[3] : params[2])
      let start = min(offset, object.data.count)
      let end = min(object.data.count, start + count)
      let slice = object.data.subdata(in: start..<end)
      respond(0x2001, tid, [UInt32(slice.count)], data: slice, operation: code)
    case 0x100B:
      guard objects[params[0]] != nil else { return respond(0x2009, tid) }
      var doomed = [params[0]]
      while let next = doomed.popLast() {
        objects[next] = nil
        doomed += objects.filter { $0.value.parent == next }.map(\.key)
      }
      respond(0x2001, tid)
    case 0x100C:
      var reader = MTPReader(data ?? Data())
      _ = try? reader.u32()
      let format = (try? reader.u16()) ?? 0
      _ = try? reader.u16()
      let size = Int((try? reader.u32()) ?? 0)
      _ = try? reader.u16()
      for _ in 0..<6 { _ = try? reader.u32() }
      _ = try? reader.u32()
      _ = try? reader.u16()
      _ = try? reader.u32()
      _ = try? reader.u32()
      let name = (try? reader.string()) ?? ""
      _ = try? reader.string()
      let modified = (try? reader.string()) ?? ""
      let parent = params[1] == 0xFFFF_FFFF ? 0 : params[1]
      if objects.values.contains(where: { $0.parent == parent && $0.name == name }) {
        return respond(0x2002, tid)
      }
      let handle = nextHandle
      nextHandle += 1
      objects[handle] = Object(
        storage: params[0], parent: parent, name: name, isDirectory: format == 0x3001, data: Data(),
        modified: modified.isEmpty ? "20251126T093000" : modified)
      if format != 0x3001 { pendingSendObject = (handle, size) }
      respond(0x2001, tid, [params[0], params[1], handle])
    case 0x100D:
      guard let pending = pendingSendObject else { return respond(0x2015, tid) }
      pendingSendObject = nil
      objects[pending.handle]?.data = data ?? Data()
      respond(0x2001, tid)
    case 0x9804:
      guard objects[params[0]] != nil else { return respond(0x2009, tid) }
      var reader = MTPReader(data ?? Data())
      objects[params[0]]?.name = (try? reader.string()) ?? ""
      respond(0x2001, tid)
    case 0x1019:
      guard objects[params[0]] != nil else { return respond(0x2009, tid) }
      objects[params[0]]?.storage = params[1]
      objects[params[0]]?.parent = params[2]
      respond(0x2001, tid)
    default:
      respond(0x2005, tid)
    }
  }
}

private func provider(_ device: FakeMTPDevice) -> MTPProvider {
  MTPProvider { MTPSession(channel: device) }
}

private func path(_ value: String) throws -> RemotePath { try RemotePath(value) }

private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
  var data = Data()
  for try await chunk in stream { data.append(chunk) }
  return data
}

private func localFile(_ data: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: "mtp-test-" + UUID().uuidString)
  try data.write(to: url)
  return url
}

@Test func mtpListsFoldersAndReadsFiles() async throws {
  let device = FakeMTPDevice()
  let books = await device.add("Books")
  let content = Data((0..<10_000).map { UInt8($0 % 251) })
  await device.add("小说.epub", parent: books, data: content)
  await device.add("note.txt", data: Data("hello".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  let root = try await mtp.list(path("/"))
  #expect(Set(root.map(\.name)) == ["Books", "note.txt"])
  #expect(root.first { $0.name == "Books" }?.isDirectory == true)
  let inner = try await mtp.list(path("/Books"))
  #expect(inner.map(\.name) == ["小说.epub"])
  #expect(inner[0].size == 10_000)
  let item = try await mtp.stat(path("/Books/小说.epub"))
  #expect(item.size == 10_000 && !item.isDirectory)
  #expect(try await collect(mtp.read(path("/Books/小说.epub"), range: nil)) == content)
  #expect(try await collect(mtp.read(path("/Books/小说.epub"), range: 100..<612)) == content[100..<612])
  // 读超过文件末尾只拿到剩下的部分
  #expect(try await collect(mtp.read(path("/note.txt"), range: 2..<100)) == Data("llo".utf8))
  await #expect(throws: RemoteError.posix(ENOENT)) { try await mtp.stat(path("/missing")) }
  let space = try await mtp.spaceInfo()
  #expect(space.total == 64_000_000_000 && space.available == 20_000_000_000)
}

// 设备锁屏时不收命令：连接时隔一会儿再试，解锁后自动连上
@Test func mtpWaitsForLockedDevice() async throws {
  let device = FakeMTPDevice()
  await device.add("note.txt", data: Data("hello".utf8))
  await device.ignoreWrites(3)
  let mtp = MTPProvider(name: "Leaf5", retryInterval: .milliseconds(10)) { MTPSession(channel: device) }
  try await mtp.connect()
  #expect(try await mtp.list(path("/")).map(\.name) == ["note.txt"])
}

// 锁屏时能答话但还没开放存储：等到解锁、存储出现再连上，不立即报错
@Test func mtpWaitsUntilStorageIsUnlocked() async throws {
  let device = FakeMTPDevice(storages: [:])
  let mtp = MTPProvider(retryInterval: .milliseconds(10)) { MTPSession(channel: device) }
  Task {
    try await Task.sleep(for: .milliseconds(50))
    await device.setStorages([0x10001: "内部共享存储空间"])
  }
  try await mtp.connect()
  #expect(try await mtp.list(path("/")).isEmpty)
}

// 设备没声明改名操作：不能放行覆盖流程（它要先删原件再把暂存文件改名）
@Test func mtpCapabilitiesFollowTheDevice() async throws {
  let device = FakeMTPDevice()
  await device.setOperations(await device.operations.subtracting([0x9804]))
  let mtp = provider(device)
  try await mtp.connect()
  #expect(!mtp.capabilities.canRename)
  #expect(mtp.capabilities.canWrite && mtp.capabilities.canDelete && mtp.capabilities.canMove)
}

// 一直不收命令：等满时限后报具体原因，写上设备名和该在设备上做什么
@Test func mtpReportsDeviceThatNeverWakes() async throws {
  let device = FakeMTPDevice()
  await device.ignoreWrites(.max)
  let mtp = MTPProvider(name: "Leaf5", wakeTimeout: 0.1, retryInterval: .milliseconds(10)) {
    MTPSession(channel: device)
  }
  do {
    try await mtp.connect()
    Issue.record("不该连上")
  } catch RemoteError.failed(let code, let message) {
    #expect(code == EHOSTDOWN)
    #expect(message == LF("“%@”没有回应。请唤醒并解锁设备，设备上弹出 USB 用途选择时选“文件传输”；已经解锁还不行就重新插拔数据线", "Leaf5"))
  }
}

// 数据正好是包长整数倍：有的设备补零长度包，有的不补而把响应并进同一次传输
@Test(arguments: [true, false]) func mtpHandlesPacketAlignedData(zlp: Bool) async throws {
  let device = FakeMTPDevice()
  await device.setSendsZLP(zlp)
  // 12 字节头 + 500 字节 = 512
  let content = Data(repeating: 7, count: 500)
  await device.add("aligned.bin", data: content)
  let mtp = provider(device)
  try await mtp.connect()
  #expect(try await collect(mtp.read(path("/aligned.bin"), range: nil)) == content)
  #expect(try await mtp.list(path("/")).count == 1)
}

@Test func mtpReadsWholeObjectWithoutPartialSupport() async throws {
  let device = FakeMTPDevice()
  await device.setOperations([0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009])
  let content = Data((0..<3000).map { UInt8($0 % 200) })
  await device.add("a.bin", data: content)
  let mtp = provider(device)
  try await mtp.connect()
  #expect(try await collect(mtp.read(path("/a.bin"), range: nil)) == content)
}

@Test func mtpWritesNewFilesAndLeavesReplacementToTheVolume() async throws {
  let device = FakeMTPDevice()
  let folder = await device.add("Download")
  await device.add("old.txt", parent: folder, data: Data("old".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  let fresh = Data((0..<2_000_000).map { UInt8($0 % 13) })
  try await mtp.write(path("/Download/new.bin"), from: localFile(fresh))
  #expect(await device.child("new.bin", of: folder)?.data == fresh)
  // 已有同名文件不直接覆盖
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await mtp.write(path("/Download/old.txt"), from: localFile(Data("x".utf8)))
  }
  #expect(await device.child("old.txt", of: folder)?.data == Data("old".utf8))
  // 卷后端的替换步骤：传到暂存名、删旧文件、暂存改成原名
  try await mtp.write(path("/Download/.old.txt.diskit-upload-1"), from: localFile(Data("new content".utf8)))
  try await mtp.remove(path("/Download/old.txt"), recursive: false)
  try await mtp.move(path("/Download/.old.txt.diskit-upload-1"), to: path("/Download/old.txt"))
  #expect(await device.names(in: folder) == ["new.bin", "old.txt"])
  #expect(await device.child("old.txt", of: folder)?.data == Data("new content".utf8))
  #expect(try await mtp.stat(path("/Download/old.txt")).size == 11)
  // 正好对齐包长的上传也要能结束
  try await mtp.write(path("/Download/aligned.bin"), from: localFile(Data(repeating: 1, count: 500)))
  #expect(await device.child("aligned.bin", of: folder)?.data.count == 500)
}

// 设备上改了名，旧路径不能再指到这个文件
@Test func mtpRechecksObjectsChangedOnTheDevice() async throws {
  let device = FakeMTPDevice()
  let handle = await device.add("a.txt", data: Data("a".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  #expect(try await mtp.list(path("/")).map(\.name) == ["a.txt"])
  await device.renameOnDevice(handle, to: "b.txt")
  await #expect(throws: RemoteError.posix(ENOENT)) { try await mtp.remove(path("/a.txt"), recursive: false) }
  #expect(await device.names() == ["b.txt"])
  await #expect(throws: RemoteError.posix(ENOENT)) { try await mtp.stat(path("/a.txt")) }
  #expect(try await mtp.stat(path("/b.txt")).size == 1)
  // 旧名字空出来了，可以新建
  try await mtp.write(path("/a.txt"), from: localFile(Data("new".utf8)))
  #expect(await device.names() == ["a.txt", "b.txt"])
}

// 跨目录移动成功、改名被拒：文件回到原处
@Test func mtpMovesBackWhenRenameAfterMoveFails() async throws {
  let device = FakeMTPDevice()
  await device.setOperations([
    0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x100B, 0x100C, 0x100D, 0x1019, 0x95C1,
  ])
  let from = await device.add("From")
  await device.add("To")
  await device.add("a.txt", parent: from, data: Data("a".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  await #expect(throws: RemoteError.self) { try await mtp.move(path("/From/a.txt"), to: path("/To/b.txt")) }
  #expect(await device.names(in: from) == ["a.txt"])
  #expect(try await mtp.list(path("/From")).map(\.name) == ["a.txt"])
}

@Test func mtpCreatesRemovesAndMoves() async throws {
  let device = FakeMTPDevice()
  let mtp = provider(device)
  try await mtp.connect()
  try await mtp.makeDirectory(path("/Notes"))
  await #expect(throws: RemoteError.posix(EEXIST)) { try await mtp.makeDirectory(path("/Notes")) }
  try await mtp.write(path("/Notes/a.txt"), from: localFile(Data("a".utf8)))
  await #expect(throws: RemoteError.posix(ENOTEMPTY)) {
    try await mtp.remove(path("/Notes"), recursive: false)
  }
  // 同目录改名
  try await mtp.move(path("/Notes/a.txt"), to: path("/Notes/b.txt"))
  #expect(try await mtp.list(path("/Notes")).map(\.name) == ["b.txt"])
  // 跨目录移动并改名
  try await mtp.makeDirectory(path("/Archive"))
  try await mtp.move(path("/Notes/b.txt"), to: path("/Archive/c.txt"))
  #expect(try await mtp.list(path("/Notes")).isEmpty)
  #expect(try await mtp.list(path("/Archive")).map(\.name) == ["c.txt"])
  // 移到根目录
  try await mtp.move(path("/Archive/c.txt"), to: path("/c.txt"))
  let notes = try #require(await device.handle("Notes"))
  #expect(await device.child("c.txt")?.data == Data("a".utf8))
  try await mtp.remove(path("/Notes"), recursive: false)
  try await mtp.remove(path("/Archive"), recursive: true)
  #expect(await device.names() == ["c.txt"])
  #expect(await device.objects[notes] == nil)
}

@Test func mtpShowsEachStorageAsFolderWhenThereAreSeveral() async throws {
  let device = FakeMTPDevice(storages: [0x10001: "内部共享存储空间", 0x20001: "SD 卡"])
  await device.add("DCIM", storage: 0x20001)
  let mtp = provider(device)
  try await mtp.connect()
  #expect(Set(try await mtp.list(path("/")).map(\.name)) == ["内部共享存储空间", "SD 卡"])
  #expect(try await mtp.list(path("/SD 卡")).map(\.name) == ["DCIM"])
  try await mtp.makeDirectory(path("/SD 卡/Books"))
  #expect(await device.objects.values.contains { $0.name == "Books" && $0.storage == 0x20001 })
  // 卷根目录下不能直接放文件
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await mtp.write(path("/x.txt"), from: localFile(Data("x".utf8)))
  }
}

// 锁屏时 Android 不给存储
@Test func mtpExplainsMissingStorage() async throws {
  let device = FakeMTPDevice(storages: [:])
  let mtp = MTPProvider(wakeTimeout: 0.1, retryInterval: .milliseconds(10)) { MTPSession(channel: device) }
  await #expect(
    throws: RemoteError.failed(
      EACCES, L("设备没有提供可访问的存储。请解锁设备，并在设备的 USB 选项里选“文件传输”后重试"))
  ) { try await mtp.connect() }
}

// 上次没关掉的会话：先关再开
@Test func mtpReopensAnAlreadyOpenSession() async throws {
  let device = FakeMTPDevice()
  _ = try await MTPSession(channel: device).run(.openSession, [1])
  let mtp = provider(device)
  try await mtp.connect()
  #expect(Array(await device.log.prefix(5)) == [0x1002, 0x1001, 0x1002, 0x1003, 0x1002])
  #expect(await device.sessionOpen)
  #expect(try await mtp.list(path("/")).isEmpty)
}

@Test func mtpResponseCodesMapToFinderErrors() {
  #expect(MTPResponse.error(0x2009, operation: .getObjectInfo).errno == ENOENT)
  #expect(MTPResponse.error(0x200C, operation: .sendObject).errno == ENOSPC)
  #expect(MTPResponse.error(0x200E, operation: .deleteObject).errno == EACCES)
  #expect(
    MTPResponse.error(0x2002, operation: .sendObject)
      == .failed(EIO, LF("设备拒绝了 %@ 操作：响应码 0x%@（%@）", "SendObject", "2002", "GeneralError")))
}

@Test func mtpInterfaceClassification() {
  // 文石 Leaf5 实测：厂商自定义类别，接口名 MTP，厂商 ID 用的是谷歌的
  let leaf = MTPUSB.Interface(interfaceClass: 0xff, subclass: 0xff, protocolCode: 0, name: "MTP")
  #expect(MTPUSB.isMTP(leaf, vendorID: 0x18d1))
  #expect(MTPUSB.isMTP(leaf, vendorID: 0x1234))
  let ptp = MTPUSB.Interface(interfaceClass: 6, subclass: 1, protocolCode: 1, name: "")
  #expect(MTPUSB.isMTP(ptp, vendorID: 0x2717))
  let lg = MTPUSB.Interface(interfaceClass: 6, subclass: 1, protocolCode: 1, name: "MTP")
  #expect(MTPUSB.isMTP(lg, vendorID: 0x1004))
  // 索尼相机不是安卓设备；接口名写了 MTP 的相机也只留在相机列表里
  #expect(!MTPUSB.isMTP(ptp, vendorID: 0x054c))
  #expect(!MTPUSB.isMTP(lg, vendorID: 0x04b0))
  let adb = MTPUSB.Interface(interfaceClass: 0xff, subclass: 0x42, protocolCode: 1, name: "ADB Interface")
  #expect(!MTPUSB.isMTP(adb, vendorID: 0x18d1))
  #expect(MTPUSB.isADB(adb))
  let other = MTPUSB.Interface(interfaceClass: 0xff, subclass: 0xff, protocolCode: 0, name: "Vendor")
  #expect(!MTPUSB.isMTP(other, vendorID: 0x18d1))
}

@Test func mtpDatesUseDeviceLocalTimeUnlessZoned() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let local = try #require(MTPDataset.date("20251126T093000"))
  #expect(calendar.component(.hour, from: local) == 9)
  let utc = try #require(MTPDataset.date("20251126T093000.0Z"))
  #expect(utc == Date(timeIntervalSince1970: 1_764_149_400))
  let zoned = try #require(MTPDataset.date("20251126T173000+0800"))
  #expect(zoned == utc)
  #expect(MTPDataset.date("") == nil)
}

@Test func androidFileTransferOccupantGetsSpecificAdvice() {
  #expect(
    USBTransport.occupied(by: "pid 2921, Android File Tra", role: .mtp)
      == .failed(
        EBUSY,
        L("设备正被 Android File Transfer 占用，请退出它后重试。插上设备时登录项“Android File Transfer Agent”会自动打开它，可在“系统设置 > 通用 > 登录项与扩展”里关掉。")))
  #expect(
    USBTransport.occupied(by: "pid 7, OpenMTP", role: .mtp)
      == .failed(EBUSY, LF("设备的 USB 文件传输接口正被电脑上的“%@”（进程 %@）占用，关掉它后重试", "OpenMTP", "7")))
}

// 设备上把文件夹改了名：旧路径下的文件不能再被删
@Test func mtpRechecksParentFoldersBeforeChanges() async throws {
  let device = FakeMTPDevice()
  let books = await device.add("Books")
  await device.add("a.epub", parent: books, data: Data("a".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  #expect(try await mtp.list(path("/Books")).map(\.name) == ["a.epub"])
  await device.renameOnDevice(books, to: "Archive")
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await mtp.remove(path("/Books/a.epub"), recursive: false)
  }
  #expect(await device.child("a.epub", of: books) != nil)
  #expect(try await mtp.list(path("/Archive")).map(\.name) == ["a.epub"])
}

// 设备那边的会话没了：按断线报，重连后接着用
@Test func mtpTreatsLostDeviceSessionAsDisconnect() async throws {
  let device = FakeMTPDevice()
  await device.add("a.txt", data: Data("a".utf8))
  let mtp = provider(device)
  try await mtp.connect()
  await device.closeSessionOnDevice()
  do {
    _ = try await mtp.list(path("/"))
    Issue.record("应该报断线")
  } catch let error as RemoteError {
    #expect(error.errno == ENOTCONN)
  }
  await #expect(throws: RemoteError.notConnected) { try await mtp.list(path("/")) }
  try await mtp.connect()
  #expect(try await mtp.list(path("/")).map(\.name) == ["a.txt"])
}

// 新连接先让设备放弃上一个程序没做完的事务
@Test func mtpResetsTheDeviceWhenConnecting() async throws {
  let device = FakeMTPDevice()
  let mtp = provider(device)
  try await mtp.connect()
  #expect(await device.cancels == 1)
}

@Test func mtpSendsTheLocalModificationTime() async throws {
  let device = FakeMTPDevice()
  let mtp = provider(device)
  try await mtp.connect()
  let file = try localFile(Data("x".utf8))
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
  try await mtp.write(path("/x.txt"), from: file)
  #expect(await device.child("x.txt")?.modified == MTPDataset.dateString(date))
  #expect(try await mtp.stat(path("/x.txt")).modified == date)
}
