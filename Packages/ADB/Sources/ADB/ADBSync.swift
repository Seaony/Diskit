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
      guard error == 0 else {
        let code = ADBErrno.darwin(error)
        // 对不上 macOS 的 Linux 错误码，原样报出来
        if code == EIO, error != 5 {
          throw RemoteError.failed(EIO, LF("手机返回 Linux 错误码 %@", String(error)))
        }
        throw RemoteError.posix(code)
      }
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
  static func mapped(_ path: RemotePath, sdPath: String?) -> String {
    if path.value == "/" { return "/sdcard" }
    if let sdPath, path.value == "/SD 卡" || path.value.hasPrefix("/SD 卡/") {
      return sdPath + path.value.dropFirst("/SD 卡".count)
    }
    return "/sdcard" + path.value
  }
  static func failure(_ session: any ADBStreamSession, length: UInt32) async throws -> RemoteError {
    guard length <= 65_536 else { return .protocolError }
    let original = String(decoding: try await session.readExactly(Int(length)), as: UTF8.self)
    let text = original.lowercased()
    if text.contains("permission denied") { return .posix(EACCES) }
    if text.contains("no such file") { return .posix(ENOENT) }
    if text.contains("no space") { return .posix(ENOSPC) }
    return .failed(EIO, LF("手机返回错误：%@", original))
  }
}
