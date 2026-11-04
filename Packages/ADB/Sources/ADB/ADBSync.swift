import Core
import Foundation

public enum ADBSync {
  static func id(_ text: String) -> UInt32 {
    text.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
  }
  static func request(_ command: String, _ path: String) throws -> Data {
    let bytes = Data(path.utf8)
    guard bytes.count <= 1024, !path.contains("\0") else { throw RemoteError.invalidPath }
    var data = Data()
    data.appendLE(id(command))
    data.appendLE(UInt32(bytes.count))
    data.append(bytes)
    return data
  }
  public static func decodeStat(_ data: Data, path: RemotePath, v2: Bool) throws -> RemoteItem {
    var r = BinaryReader(data)
    let command = try r.u32()
    guard command == id(v2 ? "STA2" : "STAT") || (v2 && command == id("LST2")) else {
      throw RemoteError.protocolError
    }
    let mode: UInt32
    let size: UInt64
    let modified: Int64
    if v2 {
      let error = try r.u32()
      guard error == 0 else { throw RemoteError.posix(Int32(bitPattern: error)) }
      _ = try r.u64()
      _ = try r.u64()
      mode = try r.u32()
      _ = try r.u32()
      _ = try r.u32()
      _ = try r.u32()
      size = try r.u64()
      _ = try r.u64()
      modified = Int64(bitPattern: try r.u64())
      _ = try r.u64()
    } else {
      mode = try r.u32()
      size = UInt64(try r.u32())
      modified = Int64(try r.u32())
      guard mode != 0 else { throw RemoteError.posix(ENOENT) }
    }
    guard size <= Int64.max, r.position == data.count else { throw RemoteError.protocolError }
    return RemoteItem(
      path: path, name: path.value.split(separator: "/").last.map(String.init) ?? "/",
      isDirectory: mode & 0xf000 == 0x4000, size: Int64(size),
      modified: Date(timeIntervalSince1970: Double(modified)))
  }
  public static func decodeDent(_ header: Data, name: String, parent: RemotePath, v2: Bool) throws
    -> RemoteItem
  {
    guard header.count == (v2 ? 76 : 20) else { throw RemoteError.protocolError }
    var r = BinaryReader(header)
    guard try r.u32() == id(v2 ? "DNT2" : "DENT") else { throw RemoteError.protocolError }
    var stat = Data()
    stat.appendLE(id(v2 ? "STA2" : "STAT"))
    stat.append(header.dropFirst(4).dropLast(4))
    var lengthReader = BinaryReader(Data(header.suffix(4)))
    guard try lengthReader.u32() == name.utf8.count else { throw RemoteError.protocolError }
    var item = try decodeStat(stat, path: parent.appending(name), v2: v2)
    item.name = name
    return item
  }
  static func failure(_ session: ADBSession, length: UInt32) async throws -> RemoteError {
    guard length <= 65_536 else { return .protocolError }
    let text = String(decoding: try await session.readExactly(Int(length)), as: UTF8.self)
      .lowercased()
    if text.contains("permission denied") { return .posix(EACCES) }
    if text.contains("no such file") { return .posix(ENOENT) }
    if text.contains("no space") { return .posix(ENOSPC) }
    return .posix(EIO)
  }
}

public actor ADBProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: false)
  private var session: ADBSession
  private let reconnect: (@Sendable () async throws -> ADBSession)?
  private var needsNewSession = false
  private var connecting = false
  private var connected = false
  private var busy = false
  private var sdPath: String?
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }
  public init(
    session: ADBSession, reconnect: (@Sendable () async throws -> ADBSession)? = nil
  ) {
    self.session = session
    self.reconnect = reconnect
  }
  public static func usb(serial: String) throws -> ADBProvider {
    ADBProvider(
      session: try usbSession(serial: serial), reconnect: { try usbSession(serial: serial) })
  }
  static func usbSession(serial: String) throws -> ADBSession {
    guard let device = ADBUSB.devices().first(where: { $0.serial == serial }) else {
      throw RemoteError.notConnected
    }
    return ADBSession(transport: try USBTransport(device: device))
  }
  public func connect() async throws {
    guard !connecting else { throw RemoteError.posix(EBUSY) }
    guard !connected else { return }
    connecting = true
    defer { connecting = false }
    do {
      if needsNewSession {
        guard let reconnect else { throw RemoteError.notConnected }
        session = try await reconnect()
        needsNewSession = false
      }
      try await session.connect()
      connected = true
      if await session.features.contains("shell_v2") {
        let output = try await shell(
          #"for p in /storage/????-????; do if [ -d "$p" ]; then printf '%s\n' "$p"; fi; done"#)
        sdPath = String(decoding: output, as: UTF8.self).split(separator: "\n").first.map(
          String.init)
      }
    } catch {
      await disconnect()
      throw error
    }
  }
  public func disconnect() async {
    connected = false
    needsNewSession = true
    busy = false
    sdPath = nil
    await session.disconnect()
  }
  private func operationFailed(_ error: Error) async {
    let reusable = await session.recoverAfterOperationError(error)
    busy = false
    if !reusable {
      connected = false
      needsNewSession = true
      sdPath = nil
    }
  }
  private func begin() throws {
    guard connected else { throw RemoteError.notConnected }
    guard !busy else { throw RemoteError.posix(EBUSY) }
    busy = true
  }
  private func mapped(_ path: RemotePath) -> String {
    if path.value == "/" { return "/sdcard" }
    if let sdPath, path.value == "/SD 卡" || path.value.hasPrefix("/SD 卡/") {
      return sdPath + path.value.dropFirst("/SD 卡".count)
    }
    if path.value == "/sdcard" || path.value.hasPrefix("/sdcard/")
      || path.value.hasPrefix("/storage/")
    {
      return path.value
    }
    return "/sdcard" + path.value
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try begin()
    defer { busy = false }
    do {
      try await session.open("sync:")
      let v2 = await session.features.contains("stat_v2")
      try await session.write(ADBSync.request(v2 ? "STA2" : "STAT", mapped(path)))
      let bytes = try await session.readExactly(v2 ? 72 : 16)
      let item = try ADBSync.decodeStat(bytes, path: path, v2: v2)
      try await session.closeService()
      return item
    } catch {
      await operationFailed(error)
      throw error
    }
  }
  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try begin()
    defer { busy = false }
    do {
      try await session.open("sync:")
      let v2 = await session.features.contains("ls_v2")
      try await session.write(ADBSync.request(v2 ? "LIS2" : "LIST", mapped(path)))
      var result: [RemoteItem] = []
      while true {
        let prefix = try await session.readExactly(8)
        var p = BinaryReader(prefix)
        let command = try p.u32()
        let value = try p.u32()
        if command == ADBSync.id("FAIL") { throw try await ADBSync.failure(session, length: value) }
        let rest = try await session.readExactly((v2 ? 76 : 20) - 8)
        if command == ADBSync.id("DONE") { break }
        var lengthReader = BinaryReader(Data(rest.suffix(4)))
        let length = try lengthReader.u32()
        guard length <= 255 else { throw RemoteError.protocolError }
        let bytes = try await session.readExactly(Int(length))
        guard let name = String(data: bytes, encoding: .utf8) else {
          throw RemoteError.protocolError
        }
        if name == "." || name == ".." { continue }
        result.append(try ADBSync.decodeDent(prefix + rest, name: name, parent: path, v2: v2))
      }
      try await session.closeService()
      if path.value == "/", sdPath != nil {
        result.append(
          RemoteItem(
            path: try RemotePath("/SD 卡"), name: "SD 卡", isDirectory: true, size: 0,
            modified: Date(timeIntervalSince1970: 0)))
      }
      return result
    } catch {
      await operationFailed(error)
      throw error
    }
  }
  public func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > {
    guard range == nil else { throw RemoteError.unsupported }
    let item = try await stat(path)
    let v2 = await session.features.contains("sendrecv_v2")
    guard v2 || item.size <= UInt32.max else { throw RemoteError.tooLarge }
    try begin()
    do {
      try await session.open("sync:")
      try await session.write(ADBSync.request(v2 ? "RCV2" : "RECV", mapped(path)))
      if v2 {
        var setup = Data()
        setup.appendLE(ADBSync.id("RCV2"))
        setup.appendLE(0)
        try await session.write(setup)
      }
      let cursor = ADBReadCursor(
        session: session, maximum: v2 ? Int64.max : Int64(UInt32.max),
        finished: { await self.endRead(reusable: $0) })
      return AsyncThrowingStream(unfolding: { try await cursor.next() })
    } catch {
      await operationFailed(error)
      throw error
    }
  }
  private func endRead(reusable: Bool) {
    busy = false
    if !reusable {
      connected = false
      needsNewSession = true
      sdPath = nil
    }
  }
  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let size = try localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let v2 = await session.features.contains("sendrecv_v2")
    guard v2 || size <= UInt32.max else { throw RemoteError.tooLarge }
    try begin()
    defer { busy = false }
    let file = try FileHandle(forReadingFrom: localFile)
    defer { try? file.close() }
    do {
      try await session.open("sync:")
      try await session.write(
        ADBSync.request(v2 ? "SND2" : "SEND", mapped(path) + (v2 ? "" : ",33206")))
      if v2 {
        var setup = Data()
        setup.appendLE(ADBSync.id("SND2"))
        setup.appendLE(0o100664)
        setup.appendLE(0)
        try await session.write(setup)
      }
      var sent: Int64 = 0
      while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
        try Task.checkCancellation()
        var frame = Data()
        frame.appendLE(ADBSync.id("DATA"))
        frame.appendLE(UInt32(chunk.count))
        frame.append(chunk)
        try await session.write(frame, timeout: 60)
        sent += Int64(chunk.count)
        progress?(sent, Int64(size))
      }
      var done = Data()
      done.appendLE(ADBSync.id("DONE"))
      done.appendLE(UInt32(Date().timeIntervalSince1970))
      try await session.write(done, timeout: 60)
      var response = BinaryReader(try await session.readExactly(8))
      let id = try response.u32()
      let length = try response.u32()
      if id == ADBSync.id("FAIL") { throw try await ADBSync.failure(session, length: length) }
      guard id == ADBSync.id("OKAY") else { throw RemoteError.protocolError }
      try await session.closeService()
    } catch {
      await operationFailed(error)
      throw error
    }
  }
  public func makeDirectory(_ path: RemotePath) async throws {
    _ = try await shell("mkdir -p -- " + ADBShell.quote(mapped(path)))
  }
  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    _ = try await shell("rm " + (recursive ? "-rf -- " : "-- ") + ADBShell.quote(mapped(path)))
  }
  public func move(_ from: RemotePath, to: RemotePath) async throws {
    _ = try await shell("mv -- " + ADBShell.quote(mapped(from)) + " " + ADBShell.quote(mapped(to)))
  }
  public func spaceInfo() async throws -> SpaceInfo {
    let output = String(decoding: try await shell("df -k /sdcard"), as: UTF8.self)
    guard let line = output.split(separator: "\n").last else { throw RemoteError.protocolError }
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 6, let total = Int64(fields[1]), let used = Int64(fields[2]),
      total <= Int64.max / 1024
    else { throw RemoteError.protocolError }
    return SpaceInfo(total: total * 1024, used: used * 1024)
  }
  private func shell(_ command: String) async throws -> Data {
    try begin()
    defer { busy = false }
    guard await session.features.contains("shell_v2") else { throw RemoteError.unsupported }
    do {
      try await session.open("shell,v2,raw:" + command)
      var output = Data()
      var errorOutput = Data()
      var exitCode: UInt8?
      while exitCode == nil {
        let id = try await session.readExactly(1).first!
        var header = BinaryReader(try await session.readExactly(4))
        let length = try header.u32()
        guard length <= 1_048_576 else { throw RemoteError.protocolError }
        let data = try await session.readExactly(Int(length))
        switch id {
        case 1: output.append(data)
        case 2: errorOutput.append(data)
        case 3: exitCode = data.first
        default: throw RemoteError.protocolError
        }
      }
      try await session.closeService()
      guard exitCode == 0 else {
        let error = String(decoding: errorOutput, as: UTF8.self)
        if error.contains("Permission denied") { throw RemoteError.posix(EACCES) }
        if error.contains("No such file") { throw RemoteError.posix(ENOENT) }
        if error.contains("No space") { throw RemoteError.posix(ENOSPC) }
        throw RemoteError.posix(EIO)
      }
      return output
    } catch {
      await operationFailed(error)
      throw error
    }
  }
}

private actor ADBReadCursor {
  let session: ADBSession
  let finished: @Sendable (Bool) async -> Void
  let maximum: Int64
  var received: Int64 = 0
  var done = false
  init(session: ADBSession, maximum: Int64, finished: @escaping @Sendable (Bool) async -> Void) {
    self.session = session
    self.finished = finished
    self.maximum = maximum
  }
  deinit {
    if !done {
      let session = session
      let finished = finished
      Task {
        await session.disconnect()
        await finished(false)
      }
    }
  }
  func next() async throws -> Data? {
    if done { return nil }
    do {
      try Task.checkCancellation()
      var header = BinaryReader(try await session.readExactly(8, timeout: 60))
      let id = try header.u32()
      let length = try header.u32()
      if id == ADBSync.id("DONE") {
        try await session.closeService()
        done = true
        await finished(true)
        return nil
      }
      if id == ADBSync.id("FAIL") { throw try await ADBSync.failure(session, length: length) }
      guard id == ADBSync.id("DATA"), length <= 65_536 else { throw RemoteError.protocolError }
      received += Int64(length)
      guard received <= maximum else { throw RemoteError.tooLarge }
      return try await session.readExactly(Int(length), timeout: 60)
    } catch {
      done = true
      let reusable = await session.recoverAfterOperationError(error)
      await finished(reusable)
      throw error
    }
  }
}
