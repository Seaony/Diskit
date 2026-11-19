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
  static func validateResponse(_ data: Data, command: UInt16? = nil) throws {
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
    default: throw RemoteError.failed(EIO, failureReason(code, command: command))
    }
  }
  // 其他响应码没有对应的 errno：把相机回的码和 PTP 标准名称原样写给人看
  static func failureReason(_ code: UInt16, command: UInt16?) -> String {
    let codeHex = hex(code)
    let codeName = responseNames[code]
    guard let command else {
      return codeName.map { LF("相机返回 PTP 错误 0x%@：%@", codeHex, $0) }
        ?? LF("相机返回未知的 PTP 响应码 0x%@", codeHex)
    }
    let step = "0x" + hex(command) + (commandNames[command].map { " " + $0 } ?? "")
    return codeName.map { LF("相机执行 PTP 命令 %@ 时返回错误 0x%@：%@", step, codeHex, $0) }
      ?? LF("相机执行 PTP 命令 %@ 时返回未知响应码 0x%@", step, codeHex)
  }
  private static func hex(_ value: UInt16) -> String { String(format: "%04X", value) }
  // 名称取自 PTP 标准（PIMA 15740）
  private static let commandNames: [UInt16: String] = [
    0x1001: "GetDeviceInfo", 0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo",
    0x1008: "GetObjectInfo",
  ]
  private static let responseNames: [UInt16: String] = [
    0x2002: "General Error", 0x2003: "Session Not Open", 0x2004: "Invalid TransactionID",
    0x2005: "Operation Not Supported", 0x2006: "Parameter Not Supported",
    0x2007: "Incomplete Transfer", 0x2008: "Invalid StorageID", 0x2009: "Invalid ObjectHandle",
    0x200A: "DeviceProp Not Supported", 0x200B: "Invalid ObjectFormatCode",
    0x200C: "Store Full", 0x200D: "Object WriteProtected", 0x200E: "Store Read-Only",
    0x200F: "Access Denied", 0x2010: "No Thumbnail Present", 0x2011: "SelfTest Failed",
    0x2012: "Partial Deletion", 0x2013: "Store Not Available",
    0x2014: "Specification By Format Unsupported", 0x2015: "No Valid ObjectInfo",
    0x2016: "Invalid Code Format", 0x2017: "Unknown Vendor Code",
    0x2018: "Capture Already Terminated", 0x2019: "Device Busy", 0x201A: "Invalid ParentObject",
    0x201B: "Invalid DeviceProp Format", 0x201C: "Invalid DeviceProp Value",
    0x201D: "Invalid Parameter", 0x201E: "Session Already Open", 0x201F: "Transaction Cancelled",
    0x2020: "Specification of Destination Unsupported",
  ]
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
