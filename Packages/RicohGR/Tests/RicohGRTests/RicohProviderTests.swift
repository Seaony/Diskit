import Core
import Foundation
import Testing

@testable import RicohGR

@MainActor private final class CameraFixture: RicohCameraAdapter {
  enum Call: Equatable {
    case open, close, snapshot
    case read(UInt32, Int64, Int)
    case delete([UInt32])
  }
  var calls: [Call] = []
  var deadlines: [ContinuousClock.Instant] = []
  var available = true
  var opened = false
  var deleteFailure: Error?
  var failReadAt: Int64?
  var emptyReadAt: Int64?
  let jpg = Data(repeating: 0x4a, count: 1_048_576 + 17)
  let dng: Data = {
    var bytes = Data(repeating: 0x44, count: 2_097_152 + 31)
    for index in 0..<64 { bytes[1_048_560 + index] = UInt8(index) }
    return bytes
  }()
  var storages = [
    RicohStorage(id: 1, kind: .internalStorage, total: 10_000_000, free: 6_000_000),
    RicohStorage(id: 2, kind: .microSD, total: 20_000_000, free: 11_000_000),
  ]
  var entries: [RicohEntry] = []
  var data: [UInt32: Data] = [:]
  init() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    entries = [
      RicohEntry(
        handle: 10, storageID: 1, relativePath: "DCIM", isDirectory: true, size: 0, modified: date),
      RicohEntry(
        handle: 11, storageID: 1, relativePath: "DCIM/100RICOH", isDirectory: true, size: 0,
        modified: date),
      RicohEntry(
        handle: 12, storageID: 1, relativePath: "DCIM/100RICOH/R0000001.JPG", isDirectory: false,
        size: Int64(jpg.count), modified: date),
      RicohEntry(
        handle: 20, storageID: 2, relativePath: "DCIM", isDirectory: true, size: 0, modified: date),
      RicohEntry(
        handle: 21, storageID: 2, relativePath: "DCIM/100RICOH", isDirectory: true, size: 0,
        modified: date),
      RicohEntry(
        handle: 22, storageID: 2, relativePath: "DCIM/100RICOH/R0000002.DNG", isDirectory: false,
        size: Int64(dng.count), modified: date),
    ]
    data = [12: jpg, 22: dng]
  }
  func open(until deadline: ContinuousClock.Instant) async throws {
    deadlines.append(deadline)
    try await open()
  }
  func snapshot(until deadline: ContinuousClock.Instant) async throws -> RicohSnapshot {
    deadlines.append(deadline)
    return try await snapshot()
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    deadlines.append(deadline)
    try await delete(handles: handles)
  }
  func open() async throws {
    calls.append(.open)
    guard available else { throw RemoteError.notConnected }
    opened = true
  }
  func close() async {
    calls.append(.close)
    opened = false
  }
  func snapshot() async throws -> RicohSnapshot {
    calls.append(.snapshot)
    guard opened, available else { throw RemoteError.notConnected }
    return RicohSnapshot(storages: storages, entries: entries)
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    calls.append(.read(handle, offset, length))
    guard opened, available else { throw RemoteError.notConnected }
    if let failReadAt, offset >= failReadAt { throw RemoteError.posix(EIO) }
    if let emptyReadAt, offset >= emptyReadAt { return Data() }
    guard let bytes = data[handle] else { throw RemoteError.posix(ENOENT) }
    guard offset >= 0, offset <= bytes.count, length >= 0 else { throw RemoteError.posix(EINVAL) }
    return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + length))
  }
  func delete(handles: [UInt32]) async throws {
    calls.append(.delete(handles))
    guard opened, available else { throw RemoteError.notConnected }
    if let deleteFailure { throw deleteFailure }
    entries.removeAll { handles.contains($0.handle) }
    for handle in handles { data.removeValue(forKey: handle) }
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

@Test @MainActor func ricohMapsBothStoragesAndOriginalDCIMHierarchy() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  let root = try await subject.list(RemotePath("/"))
  #expect(Set(root.map(\.name)) == ["内置存储", "microSD"])
  #expect(root.allSatisfy { $0.isDirectory })
  #expect(try await subject.list(RemotePath("/内置存储")).map(\.name) == ["DCIM"])
  #expect(try await subject.list(RemotePath("/microSD/DCIM")).map(\.name) == ["100RICOH"])
  let internalPhotos = try await subject.list(RemotePath("/内置存储/DCIM/100RICOH"))
  #expect(internalPhotos.map(\.path.value) == ["/内置存储/DCIM/100RICOH/R0000001.JPG"])
  #expect(internalPhotos.first?.size == Int64(camera.jpg.count))
  let cardPhoto = try await subject.stat(RemotePath("/microSD/DCIM/100RICOH/R0000002.DNG"))
  #expect(cardPhoto.name == "R0000002.DNG")
  #expect(cardPhoto.size == Int64(camera.dng.count))
  #expect(cardPhoto.modified == Date(timeIntervalSince1970: 1_700_000_000))
  await subject.disconnect()
}

@Test @MainActor func ricohCapacityUsesReportedTotalAndFreeBytes() async throws {
  let camera = CameraFixture()
  let provider = RicohProvider(adapter: camera)
  try await provider.connect()
  let space = try await provider.spaceInfo()
  #expect(space == SpaceInfo(total: 30_000_000, used: 13_000_000))
  #expect(space.available == 17_000_000)
  camera.storages = [
    RicohStorage(id: 1, kind: .internalStorage, total: 10_000_000, free: 5_000_000)
  ]
  let changed = try await provider.spaceInfo()
  #expect(changed.total == 10_000_000)
  #expect(changed.available == 5_000_000)
  await provider.disconnect()
}

@Test @MainActor func ricohReadsJPGAndDNGInBoundedChunksWithoutChangingBytes() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  for (path, expected, handle) in [
    ("/内置存储/DCIM/100RICOH/R0000001.JPG", camera.jpg, UInt32(12)),
    ("/microSD/DCIM/100RICOH/R0000002.DNG", camera.dng, UInt32(22)),
  ] {
    var result = Data()
    var sizes: [Int] = []
    for try await chunk in try await subject.read(RemotePath(path), range: nil) {
      sizes.append(chunk.count)
      result.append(chunk)
    }
    #expect(result == expected)
    #expect(sizes.count >= 2)
    #expect(sizes.allSatisfy { $0 > 0 && $0 <= 1_048_576 })
    let reads = camera.calls.compactMap { call -> (Int64, Int)? in
      if case .read(let id, let offset, let length) = call, id == handle { return (offset, length) }
      return nil
    }
    #expect(reads.first?.0 == 0)
    #expect(reads.allSatisfy { $0.1 <= 1_048_576 })
  }
  await subject.disconnect()
}

@Test @MainActor func ricohRangeReadReturnsOnlyRequestedBytes() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  #expect(subject.capabilities.supportsRangeRead)
  let range = Int64(1_048_570)..<Int64(1_048_590)
  var output = Data()
  for try await chunk in try await subject.read(
    RemotePath("/microSD/DCIM/100RICOH/R0000002.DNG"), range: range)
  {
    output.append(chunk)
  }
  #expect(output == camera.dng.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
  #expect(camera.calls.contains(.read(22, range.lowerBound, Int(range.count))))
  await subject.disconnect()
}

@Test @MainActor func ricohDeletesPhotoAndRefreshesListing() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  try await subject.remove(RemotePath("/内置存储/DCIM/100RICOH/R0000001.JPG"), recursive: false)
  #expect(camera.calls.contains(.delete([12])))
  #expect(try await subject.list(RemotePath("/内置存储/DCIM/100RICOH")).isEmpty)
  #expect(camera.data[12] == nil)
  await subject.disconnect()
}

@Test @MainActor func ricohRejectedDeletionReturnsPermissionErrorAndKeepsFile() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  camera.deleteFailure = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
  await expectPOSIX(EACCES) {
    try await subject.remove(RemotePath("/microSD/DCIM/100RICOH/R0000002.DNG"), recursive: false)
  }
  #expect(camera.data[22] != nil)
  #expect(camera.calls.contains(.delete([22])))
  await subject.disconnect()
}

@Test @MainActor func ricohWriteOperationsFailReadOnlyWithoutCallingCamera() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  #expect(!subject.capabilities.canWrite)
  #expect(!subject.capabilities.canRename)
  #expect(!subject.capabilities.canMove)
  for connected in [false, true] {
    if connected { try await subject.connect() }
    let before = camera.calls
    await expectPOSIX(EROFS) {
      try await subject.write(RemotePath("/new.JPG"), from: URL(fileURLWithPath: "/does-not-exist"))
    }
    await expectPOSIX(EROFS) { try await subject.makeDirectory(RemotePath("/new")) }
    await expectPOSIX(EROFS) { try await subject.move(RemotePath("/old"), to: RemotePath("/new")) }
    #expect(camera.calls == before)
  }
  await subject.disconnect()
}

@Test @MainActor func ricohRejectsMissingPathsAndFileDirectoryMismatch() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  await expectPOSIX(ENOENT) { _ = try await subject.stat(RemotePath("/microSD/missing.JPG")) }
  await expectPOSIX(ENOTDIR) {
    _ = try await subject.list(RemotePath("/内置存储/DCIM/100RICOH/R0000001.JPG"))
  }
  let readCalls = camera.calls.filter {
    if case .read = $0 { return true }
    return false
  }
  await expectPOSIX(EISDIR) {
    let stream = try await subject.read(RemotePath("/microSD/DCIM"), range: nil)
    for try await _ in stream {}
  }
  #expect(
    camera.calls.filter {
      if case .read = $0 { return true }
      return false
    } == readCalls)
  await expectPOSIX(EACCES) { try await subject.remove(RemotePath("/内置存储/DCIM"), recursive: true) }
  #expect(
    !camera.calls.contains {
      if case .delete = $0 { return true }
      return false
    })
  await subject.disconnect()
}

@Test @MainActor func ricohDisconnectAndReadFailureSurfaceAsIOErrors() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  camera.failReadAt = 1_048_576
  var received = 0
  await expectPOSIX(EIO) {
    for try await chunk in try await subject.read(
      RemotePath("/microSD/DCIM/100RICOH/R0000002.DNG"), range: nil)
    {
      received += chunk.count
    }
  }
  #expect(received == 1_048_576)
  camera.available = false
  await expectPOSIX(EIO) { _ = try await subject.list(RemotePath("/")) }
  await subject.disconnect()
  #expect(camera.calls.contains(.close))
}

@Test @MainActor func ricohShortReadDoesNotSilentlyReturnTruncatedPhoto() async throws {
  let camera = CameraFixture()
  let subject = RicohProvider(adapter: camera)
  try await subject.connect()
  camera.emptyReadAt = 1_048_576
  await expectPOSIX(EIO) {
    for try await _ in try await subject.read(
      RemotePath("/内置存储/DCIM/100RICOH/R0000001.JPG"), range: nil)
    {}
  }
  await subject.disconnect()
}

@MainActor @Test func cameraCompoundOperationsShareOneDeadline() async throws {
  let fixture = CameraFixture()
  let provider = RicohProvider(adapter: fixture)
  try await provider.connect()
  #expect(fixture.deadlines.count == 2)
  #expect(fixture.deadlines[0] == fixture.deadlines[1])
  fixture.deadlines.removeAll()
  try await provider.remove(RemotePath("/内置存储/DCIM/100RICOH/R0000001.JPG"), recursive: false)
  #expect(fixture.deadlines.count == 2)
  #expect(fixture.deadlines[0] == fixture.deadlines[1])
}

@Test @MainActor func ricohDeletionPreservesCancellationAndMissingFile() async throws {
  let camera = CameraFixture()
  let provider = RicohProvider(adapter: camera)
  try await provider.connect()
  for error in [RemoteError.posix(ECANCELED), RemoteError.posix(ENOENT)] {
    camera.deleteFailure = error
    await #expect(throws: error) {
      try await provider.remove(RemotePath("/microSD/DCIM/100RICOH/R0000002.DNG"), recursive: false)
    }
  }
}

@Test @MainActor func ricohDuplicatePathsCannotSelectAnotherFile() async throws {
  let camera = CameraFixture()
  camera.entries.append(camera.entries[2])
  let provider = RicohProvider(adapter: camera)
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.remove(RemotePath("/内置存储/DCIM/100RICOH/R0000001.JPG"), recursive: false)
  }
  #expect(!camera.calls.contains(.delete([12])))
}

@Test @MainActor func ricohProviderReconnectsWithoutReusingOpenState() async throws {
  let camera = CameraFixture()
  let provider = RicohProvider(adapter: camera)
  try await provider.connect()
  await provider.disconnect()
  #expect(!provider.capabilities.canDelete)
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).count == 2)
  #expect(camera.calls.filter { $0 == .open }.count == 2)
}
