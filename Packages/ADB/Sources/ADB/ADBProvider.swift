import Core
import Foundation
import OSLog

public actor ADBProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)
  private var session: ADBSession
  private let reconnect: (@Sendable () async throws -> ADBSession)?
  private var needsNewSession = false
  private var connecting = false
  private var connected = false
  private var busy = false
  private var sdPath: String?
  private var rangeUnsupported = false
  private static let logger = Logger(subsystem: "com.seaony.Diskit", category: "ADB")
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
  public static func usb(serial: String, identity: ADBIdentity = ADBIdentity()) throws -> ADBProvider {
    ADBProvider(
      session: try usbSession(serial: serial, identity: identity),
      reconnect: { try usbSession(serial: serial, identity: identity) })
  }
  static func usbSession(serial: String, identity: ADBIdentity = ADBIdentity()) throws -> ADBSession {
    try usbSession(device: ADBUSB.select(params: ["serial": serial], devices: ADBUSB.devices()), identity: identity)
  }
  static func usbSession(device: ADBDevice, identity: ADBIdentity = ADBIdentity()) throws -> ADBSession {
    ADBSession(transport: try USBTransport(device: device), identity: identity)
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
      PackageDiagnostics.failure(error, category: .adb, operation: .connect)
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
  private func operationFailed(_ error: Error, releaseBusy: Bool = true) async {
    PackageDiagnostics.failure(error, category: .adb, operation: .fileOperation)
    let reusable = await session.recoverAfterOperationError(error)
    if releaseBusy { busy = false }
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
    ADBSync.mapped(path, sdPath: sdPath)
  }
  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try begin()
    defer { busy = false }
    do {
      try await session.open("sync:")
      let v2 = await session.features.contains("stat_v2")
      try await session.write(ADBSync.request(v2 ? "STA2" : "STAT", mapped(path)))
      let bytes = try await session.readExactly(v2 ? 72 : 16)
      var item = try ADBSync.decodeStat(bytes, path: path, v2: v2)
      try await session.closeService()
      if !v2, !item.isDirectory { item.size = try await legacySize(path) }
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
        // LIS2 的 error 字段非 0 表示 lstat 失败，多是列目录途中被删掉的临时文件，跳过这一项
        if v2, value != 0 { continue }
        guard let name = String(data: bytes, encoding: .utf8) else {
          // 非 UTF-8 的文件名没法在 Finder 里表示，跳过这一项，别让整个目录读失败
          Self.logger.error("跳过非 UTF-8 文件名：\(bytes.base64EncodedString(), privacy: .private)")
          continue
        }
        if name == "." || name == ".." { continue }
        result.append(try ADBSync.decodeDent(prefix + rest, name: name, parent: path, v2: v2))
      }
      try await session.closeService()
      if !v2 {
        for index in result.indices where !result[index].isDirectory {
          result[index].size = try await legacySize(result[index].path)
        }
      }
      if path.value == "/", sdPath != nil {
        guard !result.contains(where: { $0.name == "SD 卡" }) else {
          throw RemoteError.posix(EEXIST)
        }
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
    if let range {
      let data = try await readRange(path, range)
      return AsyncThrowingStream {
        $0.yield(data)
        $0.finish()
      }
    }
    let progress = self.progress
    // 总大小只用于进度显示；Core 读之前已经 stat 过，没人看进度就省掉这次往返
    let total = progress == nil ? 0 : try await stat(path).size
    let v2 = await session.features.contains("sendrecv_v2")
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
        session: session, total: total, progress: progress,
        finished: { await self.endRead(reusable: $0) })
      return AsyncThrowingStream(unfolding: { try await cursor.next() })
    } catch {
      await operationFailed(error)
      throw error
    }
  }
  // 用 dd 按 64 KiB 块读，再在本机裁掉多读的头尾：Android 8～10 的 toybox dd 还没有
  // iflag=skip_bytes,count_bytes，按块的 bs/skip/count 所有版本都支持
  private static let rangeBlock: Int64 = 65_536
  private func readRange(_ path: RemotePath, _ range: Range<Int64>) async throws -> Data {
    // 没有 shell_v2 只能用带 PTY 的 shell:，会改坏二进制数据，交给整文件读取
    guard !rangeUnsupported, await session.features.contains("shell_v2") else {
      throw RemoteError.unsupported
    }
    let block = Self.rangeBlock
    let first = range.lowerBound / block
    let count = range.upperBound / block + (range.upperBound % block == 0 ? 0 : 1) - first
    let expected = Int(count * block)
    let output: Data
    do {
      output = try await shell(
        "dd if=" + ADBShell.quote(mapped(path))
          + " bs=\(block) skip=\(first) count=\(count) status=none",
        limit: expected + 65_536)
    } catch RemoteError.unsupported {
      rangeUnsupported = true
      throw RemoteError.unsupported
    }
    guard output.count <= expected else { throw RemoteError.protocolError }
    // dd 正常退出时输出变短只会是读到了文件末尾
    let head = Int(range.lowerBound - first * block)
    guard output.count > head else { return Data() }
    return Data(output[head..<min(output.count, head + range.count)])
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
    let progress = self.progress
    let values = try localFile.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard let size = values.fileSize, let modified = values.contentModificationDate else {
      throw RemoteError.protocolError
    }
    let seconds = modified.timeIntervalSince1970.rounded(.down)
    guard seconds >= 0, seconds <= Double(UInt32.max) else { throw RemoteError.posix(EOVERFLOW) }
    let v2 = await session.features.contains("sendrecv_v2")
    try begin()
    defer { busy = false }
    let file = try FileHandle(forReadingFrom: localFile)
    defer { try? file.close() }
    let destination = mapped(path)
    let temporary = URL(filePath: destination).deletingLastPathComponent()
      .appending(path: ".diskit-upload-" + UUID().uuidString + ".tmp").path
    do {
      try await session.open("sync:")
      try await session.write(
        ADBSync.request(v2 ? "SND2" : "SEND", temporary + (v2 ? "" : ",33206")))
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
        try await session.write(frame, timeout: RemoteTimeout.transferIdle)
        sent += Int64(chunk.count)
        progress?(sent, Int64(size))
      }
      var done = Data()
      done.appendLE(ADBSync.id("DONE"))
      done.appendLE(UInt32(seconds))
      try await session.write(done, timeout: RemoteTimeout.transferIdle)
      var response = BinaryReader(try await session.readExactly(8))
      let id = try response.u32()
      let length = try response.u32()
      if id == ADBSync.id("FAIL") { throw try await ADBSync.failure(session, length: length) }
      guard id == ADBSync.id("OKAY") else { throw RemoteError.protocolError }
      try await session.closeService()
      try Task.checkCancellation()
      _ = try await executeShell(
        "mv -T -- " + ADBShell.quote(temporary) + " " + ADBShell.quote(destination))
    } catch {
      await operationFailed(error, releaseBusy: false)
      if connected {
        do { _ = try await executeShell("rm -f -- " + ADBShell.quote(temporary)) } catch {
          await operationFailed(error, releaseBusy: false)
        }
      }
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
    let source = try ADBShell.quote(mapped(from))
    let destination = try ADBShell.quote(mapped(to))
    _ = try await shell(
      """
      if [ -e \(destination) ] || [ -L \(destination) ]; then
        printf '%s\\n' 'File exists' >&2; exit 1
      fi
      mv -nT -- \(source) \(destination) || exit $?
      if [ -e \(source) ] || [ -L \(source) ]; then
        if [ -e \(destination) ] || [ -L \(destination) ]; then
          printf '%s\\n' 'File exists' >&2
        else
          printf '%s\\n' 'Move did not complete' >&2
        fi
        exit 1
      fi
      """)
  }
  public func spaceInfo() async throws -> SpaceInfo {
    let output = String(decoding: try await shell("df -k /sdcard"), as: UTF8.self)
    guard let line = output.split(separator: "\n").last else { throw RemoteError.protocolError }
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 6, let total = Int64(fields[1]), let used = Int64(fields[2]),
      let available = Int64(fields[3]), total >= 0, used >= 0, available >= 0,
      used <= total, available <= total - used, total <= Int64.max / 1024
    else { throw RemoteError.protocolError }
    return SpaceInfo(total: total * 1024, used: used * 1024, available: available * 1024)
  }
  private func legacySize(_ path: RemotePath) async throws -> Int64 {
    let bytes = try await executeShell("stat -c %s -- " + ADBShell.quote(mapped(path)))
    guard let text = String(data: bytes, encoding: .utf8),
      let size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), size >= 0
    else { throw RemoteError.protocolError }
    return size
  }
  private func shell(_ command: String, limit: Int = 1_048_576) async throws -> Data {
    try begin()
    defer { busy = false }
    do { return try await executeShell(command, limit: limit) } catch {
      await operationFailed(error)
      throw error
    }
  }

  private func executeShell(_ command: String, limit: Int = 1_048_576) async throws -> Data {
    var output = Data()
    var errorOutput = Data()
    var exitCode: UInt8?
    if await session.features.contains("shell_v2") {
      try await session.open("shell,v2,raw:" + command)
      while exitCode == nil {
        let id = try await session.readExactly(1).first!
        var header = BinaryReader(try await session.readExactly(4))
        let length = try header.u32()
        guard length <= 1_048_576 else { throw RemoteError.protocolError }
        let data = try await session.readExactly(Int(length))
        guard output.count + errorOutput.count + data.count <= limit else {
          throw RemoteError.protocolError
        }
        switch id {
        case 1: output.append(data)
        case 2: errorOutput.append(data)
        case 3:
          guard data.count == 1 else { throw RemoteError.protocolError }
          exitCode = data.first
        default: throw RemoteError.protocolError
        }
      }
    } else {
      let marker = "DISKIT_STATUS_" + UUID().uuidString + ":"
      let wrapped =
        "(\n" + command + "\n) 2>&1; diskit_status=$?; printf '\\n" + marker
        + "%s\\n' \"$diskit_status\""
      try await session.open("shell:" + wrapped)
      while let chunk = try await session.readChunk() {
        output.append(chunk)
        guard output.count <= limit else { throw RemoteError.protocolError }
      }
      guard let footer = output.range(of: Data(("\n" + marker).utf8), options: .backwards),
        let status = UInt8(
          String(decoding: output[footer.upperBound...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
      else { throw RemoteError.protocolError }
      output = Data(output[..<footer.lowerBound])
      errorOutput = output
      exitCode = status
    }
    try await session.closeService()
    guard exitCode == 0 else {
      // sh 找不到或执行不了命令
      if exitCode == 126 || exitCode == 127 { throw RemoteError.unsupported }
      let error = String(decoding: errorOutput, as: UTF8.self)
      if error.trimmingCharacters(in: .whitespacesAndNewlines) == "File exists" {
        throw RemoteError.posix(EEXIST)
      }
      if error.contains("Permission denied") { throw RemoteError.posix(EACCES) }
      if error.contains("No such file") { throw RemoteError.posix(ENOENT) }
      if error.contains("No space") { throw RemoteError.posix(ENOSPC) }
      throw RemoteError.posix(EIO)
    }
    return output
  }

}

private actor ADBReadCursor {
  let session: ADBSession
  let finished: @Sendable (Bool) async -> Void
  let total: Int64
  let progress: (@Sendable (Int64, Int64) -> Void)?
  var received: Int64 = 0
  var done = false
  init(
    session: ADBSession, total: Int64,
    progress: (@Sendable (Int64, Int64) -> Void)?,
    finished: @escaping @Sendable (Bool) async -> Void
  ) {
    self.session = session
    self.finished = finished
    self.total = total
    self.progress = progress
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
      var header = BinaryReader(
        try await session.readExactly(8, timeout: RemoteTimeout.transferIdle))
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
      let data = try await session.readExactly(Int(length), timeout: RemoteTimeout.transferIdle)
      progress?(received, total)
      return data
    } catch {
      PackageDiagnostics.failure(error, category: .adb, operation: .download)
      done = true
      let reusable = await session.recoverAfterOperationError(error)
      await finished(reusable)
      throw error
    }
  }
}
