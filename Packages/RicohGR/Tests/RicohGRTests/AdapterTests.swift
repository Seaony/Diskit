import Core
import Foundation
import ImageCaptureCore
import Testing

@testable import RicohGR

private func ptpString(_ text: String) -> Data {
  var data = Data([UInt8(text.utf16.count + 1)])
  for unit in text.utf16 {
    data.append(UInt8(truncatingIfNeeded: unit))
    data.append(UInt8(unit >> 8))
  }
  data.append(contentsOf: [0, 0])
  return data
}
private func deviceInfo(_ name: String) -> Data {
  var data = Data(repeating: 0, count: 8)
  data.append(0)
  data.append(contentsOf: [0, 0])
  data.append(Data(repeating: 0, count: 20))
  data.append(ptpString("RICOH"))
  data.append(ptpString(name))
  return data
}
private let successResponse = Data([12, 0, 0, 0, 3, 0, 1, 0x20, 1, 0, 0, 0])
private let storageInfo = Data([
  3, 0, 2, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 50, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
])

@MainActor private final class DeviceFixture: RicohDeviceAccess {
  var hasOpenSession = false
  var canDelete = true
  var supportsPTP = true
  var model = "GR IV"
  var contents: [RicohCatalogItem] = [
    .init(
      handle: 0, name: "volume", kind: .folder,
      children: [
        .init(
          handle: 2, name: "DCIM", kind: .folder,
          children: [.init(handle: 3, name: "photo.JPG", kind: .file, size: 3)])
      ])
  ]
  var commands: [Data] = []
  var deadlines: [ContinuousClock.Instant] = []
  var data: Data? = Data("abc".utf8)
  var failure: Error?
  var response = successResponse
  var storageID: UInt8 = 1
  var deleted: [UInt32] = []
  func open(until deadline: ContinuousClock.Instant) async throws {
    deadlines.append(deadline)
    hasOpenSession = true
  }
  func close() async { hasOpenSession = false }
  func command(_ bytes: Data, until deadline: ContinuousClock.Instant) async throws -> (Data, Data)
  {
    commands.append(bytes)
    deadlines.append(deadline)
    if let failure { throw failure }
    let code = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
    let payload: Data
    switch code {
    case 0x1001: payload = deviceInfo(model)
    case 0x1004: payload = Data([1, 0, 0, 0, 1, 0, 0, 0])
    case 0x1005: payload = storageInfo
    case 0x1008: payload = Data([storageID, 0, 0, 0]) + Data(repeating: 0, count: 48)
    default: throw RemoteError.protocolError
    }
    return (payload, response)
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data? {
    if let failure { throw failure }
    return data
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    if let failure { throw failure }
    deadlines.append(deadline)
    deleted += handles
  }
}

@Test @MainActor func adapterConfirmsModelMapsStorageAndKeepsTransactionSequence() async throws {
  let device = DeviceFixture()
  let adapter: ImageCaptureAdapter
  adapter = ImageCaptureAdapter(device: device)
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  try await adapter.open(until: deadline)
  let snapshot = try await adapter.snapshot(until: deadline)
  #expect(snapshot.storages == [RicohStorage(id: 1, kind: .internalStorage, total: 100, free: 50)])
  #expect(snapshot.entries.map(\.relativePath) == ["DCIM", "DCIM/photo.JPG"])
  #expect(snapshot.entries.map(\.isDirectory) == [true, false])
  #expect(device.commands.map { $0[8] } == [1, 2, 3, 4])
  #expect(device.commands.last?.suffix(4) == Data([2, 0, 0, 0]))
  #expect(device.deadlines.allSatisfy { $0 == deadline })
  #expect(try await adapter.read(handle: 3, offset: 0, length: 3) == Data("abc".utf8))
  #expect(adapter.canDelete)
  try await adapter.delete(handles: [3], until: deadline)
  #expect(device.deleted == [3])
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await adapter.read(handle: 3, offset: 0, length: 3)
  }
  await adapter.close()
  await #expect(throws: RemoteError.notConnected) { try await adapter.snapshot() }
}

@Test @MainActor func adapterRejectsWrongModelUnsupportedPTPAndCommandFailure() async throws {
  let device = DeviceFixture()
  let adapter: ImageCaptureAdapter
  adapter = ImageCaptureAdapter(device: device)
  device.supportsPTP = false
  await #expect(throws: RemoteError.unsupported) { try await adapter.open() }
  device.supportsPTP = true
  device.model = "GR III"
  do {
    try await adapter.open()
    Issue.record("应拒绝非GR IV")
  } catch { #expect((error as NSError).code == Int(ENOTSUP)) }
  device.model = "GR IV"
  device.response[6] = 0x19
  await #expect(throws: RemoteError.posix(EBUSY)) { try await adapter.open() }
  device.response = successResponse
  device.failure = RemoteError.notConnected
  await #expect(throws: RemoteError.notConnected) { try await adapter.open() }
}

@Test @MainActor func adapterRejectsMalformedCatalogWithoutPublishingHandles() async throws {
  let device = DeviceFixture()
  let adapter: ImageCaptureAdapter
  adapter = ImageCaptureAdapter(device: device)
  try await adapter.open()
  let invalid: [(RicohCatalogItem, RemoteError)] = [
    (.init(handle: 1, name: "file", kind: .file), .unsupported),
    (
      .init(
        handle: 0, name: "root", kind: .folder,
        children: [.init(handle: 2, name: "../bad", kind: .file)]), .protocolError
    ),
    (
      .init(
        handle: 0, name: "root", kind: .folder,
        children: [.init(handle: 0, name: "zero", kind: .file)]), .unsupported
    ),
    (
      .init(
        handle: 0, name: "root", kind: .folder,
        children: [.init(handle: 2, name: "bad", kind: .unsupported)]), .unsupported
    ),
    (
      .init(
        handle: 0, name: "root", kind: .folder,
        children: [
          .init(handle: 3, name: "a", kind: .file), .init(handle: 3, name: "b", kind: .file),
        ]), .protocolError
    ),
  ]
  for (root, expected) in invalid {
    device.contents = [root]
    await #expect(throws: expected) { try await adapter.snapshot() }
    await #expect(throws: RemoteError.posix(ENOENT)) {
      try await adapter.read(handle: 3, offset: 0, length: 1)
    }
  }
  device.contents = [.init(handle: 0, name: "empty", kind: .folder)]
  #expect(try await adapter.snapshot().entries.isEmpty)
  device.contents = [
    .init(
      handle: 0, name: "root", kind: .folder, children: [.init(handle: 3, name: "a", kind: .file)])
  ]
  device.storageID = 2
  await #expect(throws: RemoteError.protocolError) { try await adapter.snapshot() }
}

@Test @MainActor func adapterReadAndDeleteKeepMissingPermissionAndCancellation() async throws {
  let device = DeviceFixture()
  let adapter: ImageCaptureAdapter
  adapter = ImageCaptureAdapter(device: device)
  try await adapter.open()
  _ = try await adapter.snapshot()
  device.data = nil
  await #expect(throws: RemoteError.posix(EIO)) {
    try await adapter.read(handle: 3, offset: 0, length: 3)
  }
  device.failure = CancellationError()
  await #expect(throws: RemoteError.posix(ECANCELED)) {
    try await adapter.read(handle: 3, offset: 0, length: 3)
  }
  await #expect(throws: RemoteError.posix(ECANCELED)) { try await adapter.delete(handles: [3]) }
  device.failure = nil
  device.canDelete = false
  await #expect(throws: RemoteError.posix(EACCES)) { try await adapter.delete(handles: [3]) }
  device.canDelete = true
  await #expect(throws: RemoteError.posix(ENOENT)) { try await adapter.delete(handles: [9]) }
  device.hasOpenSession = false
  await #expect(throws: RemoteError.notConnected) {
    try await adapter.read(handle: 3, offset: 0, length: 1)
  }
  await #expect(throws: RemoteError.notConnected) { try await adapter.delete(handles: [3]) }
}

@Test func ricohNativeErrorsKeepActionablePOSIXCodes() {
  let cases: [(Int, Int32)] = [
    (ICReturn.Code.communicationTimedOut.rawValue, ETIMEDOUT),
    (ICReturn.Code.invalidParam.rawValue, EINVAL),
    (ICReturnObjectError.Code.codeObjectDataRequestTooLarge.rawValue, EFBIG),
    (ICReturnObjectError.Code.codeObjectDoesNotExist.rawValue, ENOENT),
    (ICReturn.Code.deviceNeedsCredentials.rawValue, EACCES),
    (ICReturnConnectionError.Code.sessionAlreadyOpen.rawValue, EBUSY),
    (ICLegacyReturn.Code.deviceNotFoundErr.rawValue, ENODEV),
    (ICReturnConnectionError.Code.ejectedSuddenly.rawValue, EIO),
    (ICLegacyReturn.Code.deviceUnsupportedErr.rawValue, ENOTSUP),
    (ICReturn.Code.downloadCanceled.rawValue, ECANCELED), (-99999, EIO),
  ]
  for (code, expected) in cases {
    #expect(RicohErrorMapper.map(NSError(domain: ICErrorDomain, code: code)) == .posix(expected))
  }
  #expect(RicohErrorMapper.map(CancellationError()) == .posix(ECANCELED))
  #expect(RicohErrorMapper.map(NSError(domain: NSPOSIXErrorDomain, code: 0)) == .posix(EIO))
  #expect(RicohErrorMapper.map(NSError(domain: NSPOSIXErrorDomain, code: Int.max)) == .posix(EIO))
  #expect(RicohErrorMapper.map(NSError(domain: "unknown", code: 1)) == .posix(EIO))
}

@MainActor private final class DefaultDeadlineAdapter: RicohCameraAdapter {
  var events: [String] = []
  func open() async throws { events.append("open") }
  func close() async { events.append("close") }
  func snapshot() async throws -> RicohSnapshot {
    events.append("snapshot")
    return RicohSnapshot(storages: [], entries: [])
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data { Data() }
  func delete(handles: [UInt32]) async throws { events.append("delete") }
}

@Test @MainActor func adapterDefaultDeadlineForwardsAndRejectsExpiredOperations() async throws {
  let adapter = DefaultDeadlineAdapter()
  let future = ContinuousClock.now.advanced(by: .seconds(30))
  #expect(adapter.canDelete)
  try await adapter.open(until: future)
  #expect(try await adapter.snapshot(until: future).storages.isEmpty)
  try await adapter.delete(handles: [1], until: future)
  #expect(adapter.events == ["open", "snapshot", "delete"])
  let past = ContinuousClock.now.advanced(by: .seconds(-1))
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await adapter.open(until: past) }
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await adapter.snapshot(until: past) }
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await adapter.delete(handles: [1], until: past)
  }
  #expect(adapter.events.count == 3)
}

@Test func ptpRejectsErrorResponsesAndMalformedDeviceDatasets() throws {
  for (code, error): (UInt8, RemoteError) in [
    (5, .unsupported), (9, .posix(ENOENT)), (0x13, .posix(ENODEV)), (0x19, .posix(EBUSY)),
    (0xff, .posix(EIO)),
  ] {
    var response = successResponse
    response[6] = code
    #expect(throws: error) { try RicohPTP.validateResponse(response) }
  }
  #expect(try RicohPTP.deviceModel(deviceInfo("RICOH GR IV")) == "RICOH GR IV")
  for size in [0, 7, 10, 30, 40] {
    #expect(throws: RemoteError.protocolError) {
      try RicohPTP.deviceModel(Data(deviceInfo("GR IV").prefix(size)))
    }
  }
  var tooLarge = storageInfo
  for index in 6..<14 { tooLarge[index] = 0xff }
  #expect(throws: RemoteError.unsupported) { try RicohPTP.storageInfo(tooLarge, id: 1) }
  var tooFree = storageInfo
  tooFree[14] = 101
  #expect(throws: RemoteError.unsupported) { try RicohPTP.storageInfo(tooFree, id: 1) }
}
