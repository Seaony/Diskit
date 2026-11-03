import Core
import Foundation

// 字段顺序参考标准 PTP/MTP 数据集和 AOSP frameworks/av/media/mtp。
enum RicohPTP {
  static func command(_ code: UInt16, transaction: UInt32, parameters: [UInt32]) -> Data {
    var data = Data()
    func append(_ value: UInt64, count: Int) {
      for index in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
    append(UInt64(12 + parameters.count * 4), count: 4)
    append(1, count: 2)
    append(UInt64(code), count: 2)
    append(UInt64(transaction), count: 4)
    for parameter in parameters { append(UInt64(parameter), count: 4) }
    return data
  }
  static func validateResponse(_ data: Data) throws {
    var reader = Reader(data)
    let length = try reader.u32()
    let type = try reader.u16()
    let code = try reader.u16()
    _ = try reader.u32()
    guard length == data.count, type == 3 else { throw RemoteError.protocolError }
    switch code {
    case 0x2001: return
    case 0x2005: throw RemoteError.unsupported
    case 0x2009: throw RemoteError.posix(ENOENT)
    case 0x200f: throw RemoteError.posix(EACCES)
    case 0x2013: throw RemoteError.posix(ENODEV)
    case 0x2019: throw RemoteError.posix(EBUSY)
    default: throw RemoteError.posix(EIO)
    }
  }
  static func storageIDs(_ data: Data) throws -> [UInt32] {
    var reader = Reader(data)
    let count = try reader.u32()
    guard Int(count) <= (data.count - 4) / 4 else { throw RemoteError.protocolError }
    return try (0..<count).map { _ in try reader.u32() }
  }
  static func storageInfo(_ data: Data, id: UInt32) throws -> RicohStorage {
    var reader = Reader(data)
    let type = try reader.u16()
    _ = try reader.u16()
    _ = try reader.u16()
    let total = try reader.u64()
    let free = try reader.u64()
    _ = try reader.u32()
    _ = try reader.string()
    _ = try reader.string()
    let kind: RicohStorageKind
    switch type {
    case 1, 3: kind = .internalStorage
    case 2, 4: kind = .microSD
    default: throw RemoteError.unsupported
    }
    guard total <= Int64.max, free <= total else { throw RemoteError.unsupported }
    return RicohStorage(id: id, kind: kind, total: Int64(total), free: Int64(free))
  }
  static func objectStorageID(_ data: Data) throws -> UInt32 {
    guard data.count >= 52 else { throw RemoteError.protocolError }
    var reader = Reader(data)
    return try reader.u32()
  }
  static func deviceModel(_ data: Data) throws -> String {
    var reader = Reader(data)
    _ = try reader.u16()
    _ = try reader.u32()
    _ = try reader.u16()
    _ = try reader.string()
    _ = try reader.u16()
    for _ in 0..<5 {
      let count = try reader.u32()
      for _ in 0..<count { _ = try reader.u16() }
    }
    _ = try reader.string()
    return try reader.string()
  }
  private struct Reader {
    let data: Data
    var position = 0
    init(_ data: Data) { self.data = Data(data) }
    mutating func integer(_ count: Int) throws -> UInt64 {
      guard count <= data.count - position else { throw RemoteError.protocolError }
      var value: UInt64 = 0
      for i in 0..<count { value |= UInt64(data[position + i]) << (i * 8) }
      position += count
      return value
    }
    mutating func u16() throws -> UInt16 { UInt16(try integer(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try integer(4)) }
    mutating func u64() throws -> UInt64 { try integer(8) }
    mutating func string() throws -> String {
      let count = Int(try integer(1))
      if count == 0 { return "" }
      var units: [UInt16] = []
      for _ in 0..<count { units.append(try u16()) }
      guard units.last == 0 else { throw RemoteError.protocolError }
      units.removeLast()
      return String(decoding: units, as: UTF16.self)
    }
  }
}
