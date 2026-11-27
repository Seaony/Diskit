import Core
import Foundation

// MTP（PTP 扩展）协议的操作码、响应码和数据集。参照 USB-IF《MTP v1.1》、PIMA 15740 和
// Android 的 MtpServer（frameworks/av/media/mtp）、libmtp 的实现
enum MTPOperation: UInt16 {
  case getDeviceInfo = 0x1001
  case openSession = 0x1002
  case closeSession = 0x1003
  case getStorageIDs = 0x1004
  case getStorageInfo = 0x1005
  case getObjectHandles = 0x1007
  case getObjectInfo = 0x1008
  case getObject = 0x1009
  case deleteObject = 0x100B
  case sendObjectInfo = 0x100C
  case sendObject = 0x100D
  case moveObject = 0x1019
  case getPartialObject = 0x101B
  case getObjectPropValue = 0x9803
  case setObjectPropValue = 0x9804
  // Android 扩展：64 位偏移的分段读取
  case getPartialObject64 = 0x95C1

  var name: String {
    switch self {
    case .getDeviceInfo: "GetDeviceInfo"
    case .openSession: "OpenSession"
    case .closeSession: "CloseSession"
    case .getStorageIDs: "GetStorageIDs"
    case .getStorageInfo: "GetStorageInfo"
    case .getObjectHandles: "GetObjectHandles"
    case .getObjectInfo: "GetObjectInfo"
    case .getObject: "GetObject"
    case .deleteObject: "DeleteObject"
    case .sendObjectInfo: "SendObjectInfo"
    case .sendObject: "SendObject"
    case .moveObject: "MoveObject"
    case .getPartialObject: "GetPartialObject"
    case .getObjectPropValue: "GetObjectPropValue"
    case .setObjectPropValue: "SetObjectPropValue"
    case .getPartialObject64: "GetPartialObject64"
    }
  }
}

enum MTPResponse {
  static let ok: UInt16 = 0x2001
  static let sessionAlreadyOpen: UInt16 = 0x201E
  static let sessionNotOpen: UInt16 = 0x2003

  static func name(_ code: UInt16) -> String {
    switch code {
    case 0x2002: "GeneralError"
    case 0x2003: "SessionNotOpen"
    case 0x2004: "InvalidTransactionID"
    case 0x2005: "OperationNotSupported"
    case 0x2006: "ParameterNotSupported"
    case 0x2007: "IncompleteTransfer"
    case 0x2008: "InvalidStorageID"
    case 0x2009: "InvalidObjectHandle"
    case 0x200A: "DevicePropNotSupported"
    case 0x200B: "InvalidObjectFormatCode"
    case 0x200C: "StoreFull"
    case 0x200D: "ObjectWriteProtected"
    case 0x200E: "StoreReadOnly"
    case 0x200F: "AccessDenied"
    case 0x2010: "NoThumbnailPresent"
    case 0x2013: "StoreNotAvailable"
    case 0x2014: "SpecificationByFormatUnsupported"
    case 0x2015: "NoValidObjectInfo"
    case 0x2019: "DeviceBusy"
    case 0x201A: "InvalidParentObject"
    case 0x201D: "InvalidParameter"
    case 0x201E: "SessionAlreadyOpen"
    case 0x201F: "TransactionCancelled"
    case 0xA801: "InvalidObjectPropCode"
    case 0xA802: "InvalidObjectPropFormat"
    case 0xA803: "InvalidObjectPropValue"
    case 0xA804: "InvalidObjectReference"
    case 0xA806: "InvalidDataset"
    case 0xA809: "ObjectTooLarge"
    default: "Unknown"
    }
  }

  // 设备拒绝时按含义给 Finder 对应的错误码，原始响应码和操作名一并给人看
  static func error(_ code: UInt16, operation: MTPOperation) -> RemoteError {
    let detail = LF(
      "设备拒绝了 %@ 操作：响应码 0x%@（%@）", operation.name, String(code, radix: 16, uppercase: true),
      name(code))
    let value: Int32 =
      switch code {
      case 0x2008, 0x2009, 0x201A: ENOENT
      case 0x200C: ENOSPC
      case 0x200D, 0x200E, 0x200F: EACCES
      case 0x2005, 0x2006, 0x2014: ENOTSUP
      case 0x2019: EBUSY
      case 0xA809: EFBIG
      case 0x2013: ENXIO
      default: EIO
      }
    return .failed(value, detail)
  }
}

enum MTPFormat {
  static let undefined: UInt16 = 0x3000
  static let association: UInt16 = 0x3001
}

enum MTPProperty {
  static let objectSize: UInt16 = 0xDC04
  static let objectFileName: UInt16 = 0xDC07
}

struct MTPDeviceInfo: Equatable {
  var operations: Set<UInt16>
  var manufacturer: String
  var model: String
  var serial: String
  func supports(_ operation: MTPOperation) -> Bool { operations.contains(operation.rawValue) }
}

struct MTPStorageInfo: Equatable {
  var capacity: UInt64
  var free: UInt64
  var description: String
  var label: String
  // 0 读写；1、2 只读
  var accessCapability: UInt16
}

struct MTPObjectInfo: Equatable {
  var storageID: UInt32
  var format: UInt16
  var compressedSize: UInt32
  var parent: UInt32
  var name: String
  var modified: Date?
  var isDirectory: Bool { format == MTPFormat.association }
}

// MTP 数据集都是小端序；字符串是 1 字节长度（含结尾 0 的 UTF-16 字符数）加 UTF-16LE
struct MTPReader {
  let bytes: Data
  var position = 0
  init(_ bytes: Data) { self.bytes = Data(bytes) }
  var remaining: Int { bytes.count - position }
  mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, count <= remaining else {
      throw RemoteError.malformed(L("设备返回的 MTP 数据比声明的短"))
    }
    defer { position += count }
    return bytes.subdata(in: position..<position + count)
  }
  private mutating func integer(_ count: Int) throws -> UInt64 {
    try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
  }
  mutating func u8() throws -> UInt8 { UInt8(try integer(1)) }
  mutating func u16() throws -> UInt16 { UInt16(try integer(2)) }
  mutating func u32() throws -> UInt32 { UInt32(try integer(4)) }
  mutating func u64() throws -> UInt64 { try integer(8) }
  mutating func string() throws -> String {
    let count = Int(try u8())
    guard count > 0 else { return "" }
    var units: [UInt16] = []
    for _ in 0..<count { units.append(try u16()) }
    if units.last == 0 { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
  }
  mutating func u16Array() throws -> [UInt16] {
    let count = Int(try u32())
    guard count <= remaining / 2 else { throw RemoteError.malformed(L("设备返回的 MTP 数据比声明的短")) }
    return try (0..<count).map { _ in try u16() }
  }
  mutating func u32Array() throws -> [UInt32] {
    let count = Int(try u32())
    guard count <= remaining / 4 else { throw RemoteError.malformed(L("设备返回的 MTP 数据比声明的短")) }
    return try (0..<count).map { _ in try u32() }
  }
}

extension Data {
  mutating func appendMTP(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }
  mutating func appendMTP(_ value: UInt32) {
    for offset in 0..<4 { append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
  }
  mutating func appendMTP(_ value: UInt64) {
    for offset in 0..<8 { append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
  }
  // MTP 字符串最多 255 个 UTF-16 单元（含结尾 0）
  mutating func appendMTP(string: String) throws {
    guard !string.isEmpty else {
      append(0)
      return
    }
    let units = Array(string.utf16) + [0]
    guard units.count <= 255 else { throw RemoteError.posix(ENAMETOOLONG) }
    append(UInt8(units.count))
    for unit in units { appendMTP(unit) }
  }
}

enum MTPDataset {
  static func deviceInfo(_ data: Data) throws -> MTPDeviceInfo {
    var reader = MTPReader(data)
    _ = try reader.u16()  // StandardVersion
    _ = try reader.u32()  // VendorExtensionID
    _ = try reader.u16()  // VendorExtensionVersion
    _ = try reader.string()  // VendorExtensionDesc
    _ = try reader.u16()  // FunctionalMode
    let operations = try reader.u16Array()
    _ = try reader.u16Array()  // EventsSupported
    _ = try reader.u16Array()  // DevicePropertiesSupported
    _ = try reader.u16Array()  // CaptureFormats
    _ = try reader.u16Array()  // PlaybackFormats
    let manufacturer = try reader.string()
    let model = try reader.string()
    _ = try reader.string()  // DeviceVersion
    let serial = try reader.string()
    return MTPDeviceInfo(
      operations: Set(operations), manufacturer: manufacturer, model: model, serial: serial)
  }

  static func storageInfo(_ data: Data) throws -> MTPStorageInfo {
    var reader = MTPReader(data)
    _ = try reader.u16()  // StorageType
    _ = try reader.u16()  // FilesystemType
    let access = try reader.u16()
    let capacity = try reader.u64()
    let free = try reader.u64()
    _ = try reader.u32()  // FreeSpaceInObjects
    let description = try reader.string()
    let label = try reader.string()
    return MTPStorageInfo(
      capacity: capacity, free: free, description: description, label: label,
      accessCapability: access)
  }

  static func objectInfo(_ data: Data) throws -> MTPObjectInfo {
    var reader = MTPReader(data)
    let storage = try reader.u32()
    let format = try reader.u16()
    _ = try reader.u16()  // ProtectionStatus
    let size = try reader.u32()
    _ = try reader.u16()  // ThumbFormat
    for _ in 0..<6 { _ = try reader.u32() }  // 缩略图大小、宽高，图片宽高和位深
    let parent = try reader.u32()
    _ = try reader.u16()  // AssociationType
    _ = try reader.u32()  // AssociationDesc
    _ = try reader.u32()  // SequenceNumber
    let name = try reader.string()
    let captured = try reader.string()
    let modified = try reader.string()
    return MTPObjectInfo(
      storageID: storage, format: format, compressedSize: size, parent: parent, name: name,
      modified: date(modified) ?? date(captured))
  }

  // 新建文件或文件夹时发给设备的 ObjectInfo
  static func newObject(name: String, size: Int64, isDirectory: Bool, modified: Date? = nil) throws
    -> Data
  {
    var data = Data()
    data.appendMTP(UInt32(0))  // StorageID 由命令参数指定
    data.appendMTP(isDirectory ? MTPFormat.association : MTPFormat.undefined)
    data.appendMTP(UInt16(0))  // ProtectionStatus
    // 超过 4 GB 时按协议写 0xFFFFFFFF，实际长度由数据阶段决定
    data.appendMTP(size >= Int64(UInt32.max) ? UInt32.max : UInt32(size))
    data.appendMTP(UInt16(0))  // ThumbFormat
    for _ in 0..<6 { data.appendMTP(UInt32(0)) }
    data.appendMTP(UInt32(0))  // ParentObject 由命令参数指定
    data.appendMTP(UInt16(isDirectory ? 1 : 0))  // AssociationType：1 是普通文件夹
    data.appendMTP(UInt32(0))  // AssociationDesc
    data.appendMTP(UInt32(0))  // SequenceNumber
    try data.appendMTP(string: name)
    try data.appendMTP(string: "")  // CaptureDate
    try data.appendMTP(string: modified.map(dateString) ?? "")  // ModificationDate
    try data.appendMTP(string: "")  // Keywords
    return data
  }

  // 按本机时区写成 YYYYMMDDThhmmss，和设备回报的格式一致
  static func dateString(_ date: Date) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }

  // 日期格式 YYYYMMDDThhmmss，可带 .s 和时区；不带时区按本机时区算（Android 用的就是设备本地时间）
  static func date(_ text: String) -> Date? {
    let characters = Array(text)
    guard characters.count >= 15, characters[8] == "T" else { return nil }
    func number(_ range: Range<Int>) -> Int? { Int(String(characters[range])) }
    guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
      let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
      year > 1970
    else { return nil }
    var components = DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    var rest = String(characters[15...])
    if rest.hasPrefix(".") { rest = String(rest.drop { $0 == "." || $0.isNumber }) }
    if rest == "Z" {
      components.timeZone = TimeZone(identifier: "UTC")
    } else if rest.count == 5, let sign = rest.first, sign == "+" || sign == "-",
      let hours = Int(rest.dropFirst().prefix(2)), let minutes = Int(rest.suffix(2))
    {
      let offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
      components.timeZone = TimeZone(secondsFromGMT: offset)
    } else {
      components.timeZone = .current
    }
    return Calendar(identifier: .gregorian).date(from: components)
  }
}
