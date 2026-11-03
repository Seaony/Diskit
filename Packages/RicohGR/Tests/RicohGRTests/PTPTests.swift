import Core
import Foundation
import Testing

@testable import RicohGR

// 按 AOSP MtpStorageInfo/MtpObjectInfo 字段定义排列，不是 GR IV 抓包。
private let standardStorageInfo = Data([
  3, 0, 2, 0, 0, 0,
  0x40, 0, 0, 0, 2, 0, 0, 0,
  0x20, 0, 0, 0, 1, 0, 0, 0,
  10, 0, 0, 0,
  2, 0x49, 0, 0, 0,
  2, 0x56, 0, 0, 0,
])

@Test func ptpStorageInfoPreserves64BitCapacityAndStorageKind() throws {
  let internalStorage = try RicohPTP.storageInfo(standardStorageInfo, id: 0x10001)
  #expect(internalStorage.id == 0x10001)
  #expect(internalStorage.kind == .internalStorage)
  #expect(internalStorage.total == 8_589_934_656)
  #expect(internalStorage.free == 4_294_967_328)
  for type: UInt8 in [1, 2, 3, 4] {
    var bytes = standardStorageInfo
    bytes[0] = type
    let parsed = try RicohPTP.storageInfo(bytes, id: 0x20001)
    #expect(parsed.kind == (type == 1 || type == 3 ? .internalStorage : .microSD))
  }
}

@Test func ptpStorageInfoRejectsUnknownTypeAndTruncation() throws {
  var unknown = standardStorageInfo
  unknown[0] = 0x99
  #expect(throws: RemoteError.unsupported) { try RicohPTP.storageInfo(unknown, id: 1) }
  for count in [0, 5, 13, 25, 27, standardStorageInfo.count - 1] {
    #expect(throws: RemoteError.protocolError) {
      try RicohPTP.storageInfo(Data(standardStorageInfo.prefix(count)), id: 1)
    }
  }
  var badTerminator = standardStorageInfo
  badTerminator[badTerminator.count - 2] = 1
  #expect(throws: RemoteError.protocolError) { try RicohPTP.storageInfo(badTerminator, id: 1) }
}

@Test func ptpObjectInfoAndStorageIDArrayUseLittleEndianFields() throws {
  var object = Data([0x78, 0x56, 0x34, 0x12, 1, 0x38, 0, 0, 0x34, 0x12, 0, 0])
  object.append(Data(repeating: 0, count: 40))
  #expect(try RicohPTP.objectStorageID(object) == 0x1234_5678)
  #expect(throws: RemoteError.protocolError) {
    try RicohPTP.objectStorageID(Data(object.prefix(51)))
  }
  let ids = Data([2, 0, 0, 0, 1, 0, 1, 0, 1, 0, 2, 0])
  #expect(try RicohPTP.storageIDs(ids) == [0x10001, 0x20001])
  #expect(throws: RemoteError.protocolError) { try RicohPTP.storageIDs(Data(ids.dropLast())) }
}

@Test func ptpCommandAndResponsesKeepContainerFieldsAndMapErrors() throws {
  let command = Data([16, 0, 0, 0, 1, 0, 5, 0x10, 7, 0, 0, 0, 1, 0, 1, 0])
  #expect(RicohPTP.command(0x1005, transaction: 7, parameters: [0x10001]) == command)
  let success = Data([12, 0, 0, 0, 3, 0, 1, 0x20, 7, 0, 0, 0])
  try RicohPTP.validateResponse(success)
  var denied = success
  denied[6] = 0x0f
  #expect(throws: RemoteError.posix(EACCES)) { try RicohPTP.validateResponse(denied) }
  var wrongType = success
  wrongType[4] = 2
  #expect(throws: RemoteError.protocolError) { try RicohPTP.validateResponse(wrongType) }
  #expect(throws: RemoteError.protocolError) {
    try RicohPTP.validateResponse(Data(success.dropLast()))
  }
}
