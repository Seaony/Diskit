import Core
import Foundation
import ImageCaptureCore
import Testing

@testable import CameraUSB

@MainActor private final class CameraAccessFixture: CameraUSBAccess {
  enum Call: Equatable {
    case open
    case close
    case snapshot
    case read(UInt32, Int64, Int)
    case delete([UInt32])
  }

  var calls: [Call] = []
  var canDelete: Bool
  var available = true
  var opened = false
  var deleteFailure: Error?
  var failReadAt: Int64?
  var emptyReadAt: Int64?
  let photo: Data
  var snapshotValue: CameraUSBSnapshot
  var photoData: [UInt32: Data]

  init(canDelete: Bool = true) {
    self.canDelete = canDelete
    photo = Data(repeating: 0x4a, count: 1_048_576 + 17)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    snapshotValue = CameraUSBSnapshot(
      storages: [
        CameraUSBStorage(id: "internal", name: "内置存储", total: 10, available: 6),
        CameraUSBStorage(id: "card", name: "SD 卡", total: 20, available: 11),
      ],
      entries: [
        CameraUSBEntry(
          storageID: "internal", relativePath: "DCIM", isDirectory: true, size: 0,
          modified: modified),
        CameraUSBEntry(
          storageID: "internal", relativePath: "DCIM/100FUJI", isDirectory: true, size: 0,
          modified: modified),
        CameraUSBEntry(
          storageID: "internal", relativePath: "DCIM/100FUJI/DSCF0001.JPG", isDirectory: false,
          size: Int64(photo.count), modified: modified, fileHandle: 10),
        CameraUSBEntry(
          storageID: "card", relativePath: "DCIM", isDirectory: true, size: 0,
          modified: modified),
        CameraUSBEntry(
          storageID: "card", relativePath: "DCIM/100CANON", isDirectory: true, size: 0,
          modified: modified),
        CameraUSBEntry(
          storageID: "card", relativePath: "DCIM/100CANON/IMG_0001.JPG", isDirectory: false,
          size: 32, modified: modified, fileHandle: 20),
      ])
    photoData = [10: photo, 20: Data(repeating: 0x43, count: 32)]
  }

  func open() async throws {
    calls.append(.open)
    guard available else { throw RemoteError.posix(EIO) }
    opened = true
  }

  func close() async {
    calls.append(.close)
    opened = false
  }

  func snapshot() async throws -> CameraUSBSnapshot {
    calls.append(.snapshot)
    guard opened, available else { throw RemoteError.posix(EIO) }
    return snapshotValue
  }

  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    calls.append(.read(handle, offset, length))
    guard opened, available else { throw RemoteError.posix(EIO) }
    if let failReadAt, offset >= failReadAt { throw RemoteError.posix(EIO) }
    if let emptyReadAt, offset >= emptyReadAt { return Data() }
    guard let data = photoData[handle] else { throw RemoteError.posix(ENOENT) }
    guard offset >= 0, offset <= data.count, length >= 0 else {
      throw RemoteError.posix(EINVAL)
    }
    return data.subdata(
      in: Int(offset)..<min(data.count, Int(offset) + length))
  }

  func delete(handles: [UInt32]) async throws {
    calls.append(.delete(handles))
    guard opened, available else { throw RemoteError.posix(EIO) }
    if let deleteFailure { throw deleteFailure }
    snapshotValue = CameraUSBSnapshot(
      storages: snapshotValue.storages,
      entries: snapshotValue.entries.filter { !handles.contains($0.fileHandle ?? 0) })
    for handle in handles {
      photoData.removeValue(forKey: handle)
    }
  }
}

@MainActor private func expectPOSIX(_ code: Int32, _ operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("操作应返回 POSIX 错误 \(code)")
  } catch {
    if let remote = error as? RemoteError {
      #expect(remote.errno == code)
    } else {
      let system = error as NSError
      #expect(system.domain == NSPOSIXErrorDomain && system.code == Int(code))
    }
  }
}

@Test @MainActor func providerMapsStoragesAndOriginalDCIMFolders() async throws {
  let access = CameraAccessFixture()
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  #expect(Set(try await provider.list(RemotePath("/")).map(\.name)) == ["内置存储", "SD 卡"])
  #expect(try await provider.list(RemotePath("/内置存储")).map(\.name) == ["DCIM"])
  #expect(
    try await provider.list(RemotePath("/内置存储/DCIM/100FUJI")).map(\.path.value)
      == ["/内置存储/DCIM/100FUJI/DSCF0001.JPG"])
  #expect(
    try await provider.stat(RemotePath("/SD 卡/DCIM/100CANON/IMG_0001.JPG")).size == 32)
  #expect(try await provider.spaceInfo() == SpaceInfo(total: 30, used: 13))
  await provider.disconnect()
  #expect(access.calls.contains(.close))
}

@Test @MainActor func providerReadsRequestedRangeWithoutReturningExtraBytes() async throws {
  let access = CameraAccessFixture()
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  #expect(provider.capabilities.supportsRangeRead)
  let range = Int64(1_048_570)..<Int64(1_048_590)
  var output = Data()
  for try await chunk in try await provider.read(
    RemotePath("/内置存储/DCIM/100FUJI/DSCF0001.JPG"), range: range)
  {
    output.append(chunk)
  }
  #expect(output == access.photo.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
  #expect(access.calls.contains(.read(10, range.lowerBound, Int(range.count))))
  await provider.disconnect()
}

@Test @MainActor func providerRejectsAllWriteOperationsBeforeConnecting() async throws {
  let access = CameraAccessFixture()
  let provider = CameraUSBProvider(access: access)

  #expect(!provider.capabilities.canWrite)
  #expect(!provider.capabilities.canRename)
  #expect(!provider.capabilities.canMove)
  await expectPOSIX(EROFS) {
    try await provider.write(
      RemotePath("/photo.JPG"), from: URL(fileURLWithPath: "/missing"))
  }
  await expectPOSIX(EROFS) {
    try await provider.makeDirectory(RemotePath("/new"))
  }
  await expectPOSIX(EROFS) {
    try await provider.move(RemotePath("/old"), to: RemotePath("/new"))
  }
  #expect(access.calls.isEmpty)
}

@Test @MainActor func providerDeletesWhenDeviceReportsCapability() async throws {
  let access = CameraAccessFixture(canDelete: true)
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  #expect(provider.capabilities.canDelete)
  try await provider.remove(
    RemotePath("/内置存储/DCIM/100FUJI/DSCF0001.JPG"), recursive: false)
  #expect(access.calls.contains(.delete([10])))
  #expect(access.photoData[10] == nil)
  #expect(try await provider.list(RemotePath("/内置存储/DCIM/100FUJI")).isEmpty)
  await provider.disconnect()
}

@Test @MainActor func providerHonorsReadOnlyDeleteCapability() async throws {
  let access = CameraAccessFixture(canDelete: false)
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  #expect(!provider.capabilities.canDelete)
  await expectPOSIX(EACCES) {
    try await provider.remove(
      RemotePath("/SD 卡/DCIM/100CANON/IMG_0001.JPG"), recursive: false)
  }
  #expect(
    !access.calls.contains {
      if case .delete = $0 { return true }
      return false
    })
  await provider.disconnect()
}

@Test @MainActor func providerMapsRejectedDeleteToPermissionError() async throws {
  let access = CameraAccessFixture(canDelete: true)
  access.deleteFailure = NSError(
    domain: ICErrorDomain, code: ICReturn.Code.deleteFilesFailed.rawValue)
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  await expectPOSIX(EACCES) {
    try await provider.remove(
      RemotePath("/SD 卡/DCIM/100CANON/IMG_0001.JPG"), recursive: false)
  }
  #expect(access.photoData[20] != nil)
  await provider.disconnect()
}

@Test @MainActor func providerSurfacesDisconnectAndPartialReadFailureAsIO() async throws {
  let access = CameraAccessFixture()
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  access.failReadAt = 1_048_576
  var received = 0
  await expectPOSIX(EIO) {
    for try await chunk in try await provider.read(
      RemotePath("/内置存储/DCIM/100FUJI/DSCF0001.JPG"), range: nil)
    {
      received += chunk.count
    }
  }
  #expect(received == 1_048_576)

  access.available = false
  await expectPOSIX(EIO) {
    _ = try await provider.list(RemotePath("/"))
  }
  await provider.disconnect()
  #expect(access.calls.contains(.close))
  await expectPOSIX(EIO) {
    _ = try await provider.list(RemotePath("/"))
  }
}

@Test @MainActor func providerDoesNotTreatShortReadAsEndOfFile() async throws {
  let access = CameraAccessFixture()
  let provider = CameraUSBProvider(access: access)
  try await provider.connect()

  access.emptyReadAt = 1_048_576
  await expectPOSIX(EIO) {
    for try await _ in try await provider.read(
      RemotePath("/内置存储/DCIM/100FUJI/DSCF0001.JPG"), range: nil)
    {}
  }
  await provider.disconnect()
}
