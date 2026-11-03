import Core
import Foundation

// 协议字段与版本规则见 AOSP packages/modules/adb/adb.h、adb.cpp、transport.cpp。
public enum ADBCommand: UInt32, Sendable {
  case connect = 0x4e58_4e43
  case auth = 0x4854_5541
  case open = 0x4e45_504f
  case okay = 0x5941_4b4f
  case write = 0x4554_5257
  case close = 0x4553_4c43
  case startTLS = 0x534c_5453
}

public struct ADBMessage: Equatable, Sendable {
  public let command: ADBCommand
  public let arg0: UInt32
  public let arg1: UInt32
  public let payload: Data
  public init(_ command: ADBCommand, _ arg0: UInt32 = 0, _ arg1: UInt32 = 0, payload: Data = Data())
  {
    self.command = command
    self.arg0 = arg0
    self.arg1 = arg1
    self.payload = payload
  }
  public static func checksum(_ payload: Data) -> UInt32 {
    payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
  }
  public func encoded(skipChecksum: Bool = false) -> Data {
    var data = Data()
    for word in [
      command.rawValue, arg0, arg1, UInt32(payload.count),
      skipChecksum ? 0 : Self.checksum(payload), command.rawValue ^ UInt32.max,
    ] { data.appendLE(word) }
    data.append(payload)
    return data
  }
  public static func decode(_ bytes: Data, skipChecksum: Bool = false, maxPayload: Int = 1_048_576)
    throws -> ADBMessage
  {
    var reader = BinaryReader(bytes)
    let raw = try reader.u32()
    let a = try reader.u32()
    let b = try reader.u32()
    let length = try reader.u32()
    let sum = try reader.u32()
    let magic = try reader.u32()
    guard let command = ADBCommand(rawValue: raw), magic == raw ^ UInt32.max,
      length <= maxPayload, bytes.count == 24 + Int(length)
    else { throw RemoteError.protocolError }
    let payload = try reader.take(Int(length))
    guard skipChecksum || sum == checksum(payload) else { throw RemoteError.protocolError }
    return ADBMessage(command, a, b, payload: payload)
  }
}

struct BinaryReader {
  let bytes: Data
  var position = 0
  init(_ bytes: Data) { self.bytes = Data(bytes) }
  mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, count <= bytes.count - position else { throw RemoteError.protocolError }
    defer { position += count }
    return bytes.subdata(in: position..<position + count)
  }
  mutating func u32() throws -> UInt32 {
    try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
  }
  mutating func u64() throws -> UInt64 {
    try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
  }
}

extension Data {
  mutating func appendLE(_ word: UInt32) {
    for offset in 0..<4 { append(UInt8(truncatingIfNeeded: word >> (offset * 8))) }
  }
}

public enum ADBShell {
  public static func quote(_ value: String) throws -> String {
    guard !value.contains("\0") else { throw RemoteError.invalidPath }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
