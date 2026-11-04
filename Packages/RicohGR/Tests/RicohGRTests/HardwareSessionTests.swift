import Core
import Foundation
import ImageCaptureCore
import Testing

@testable import RicohGR

@MainActor private final class RawFile: RicohHardwareFile {
  var size: Int64 = 3
  var bytes: Data? = Data("abc".utf8)
  var error: Error?
  var reads: [(Int64, Int64)] = []
  func read(offset: Int64, length: Int64, completion: @escaping @Sendable (Data?, Error?) -> Void) {
    reads.append((offset, length))
    completion(bytes, error)
  }
}
@MainActor private final class RawItem: RicohHardwareItem {
  let handle: UInt32
  var name: String?
  var modified: Date?
  var created: Date?
  var file: (any RicohHardwareFile)?
  var children: [any RicohHardwareItem]?
  init(
    handle: UInt32, name: String?, file: (any RicohHardwareFile)? = nil,
    children: [any RicohHardwareItem]? = nil
  ) {
    self.handle = handle
    self.name = name
    self.file = file
    self.children = children
  }
}
@MainActor private final class RawCamera: RicohCameraHardware {
  var hasOpenSession = false
  var isLocked = false
  var capabilities = [
    ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue,
    ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue,
  ]
  var percent = 100
  var onPercent: (() -> Void)?
  var catalogPercent: Int {
    onPercent?()
    return percent
  }
  var contents: [any RicohHardwareItem]?
  var removed: (@MainActor () -> Void)?
  var catalogReady: (@MainActor () -> Void)?
  var error: Error?
  var deleteFailed = false
  var synchronousDeleteError = false
  var events: [String] = []
  func start() { events.append("start") }
  func stop() { events.append("stop") }
  func open(completion: @escaping @Sendable (Error?) -> Void) {
    events.append("open")
    hasOpenSession = true
    completion(error)
  }
  func close(completion: @escaping @Sendable (Error?) -> Void) {
    events.append("close")
    hasOpenSession = false
    completion(error)
  }
  func command(_ data: Data, completion: @escaping @Sendable (Data, Data, Error?) -> Void) {
    completion(data, Data([1]), error)
  }
  func delete(
    _ files: [any RicohHardwareFile], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void
  ) throws {
    if synchronousDeleteError { throw RemoteError.protocolError }
    events.append("delete:\(files.count)")
    if deleteFailed { failed() }
    completion(error)
  }
}

@Test @MainActor func hardwareSessionProjectsTypesDatesAndReplacesHandleIndex() async throws {
  let camera = RawCamera()
  let file = RawFile()
  let access = ImageCaptureDeviceAccess(hardware: camera)
  #expect(access.contents.isEmpty)
  let child = RawItem(handle: 7, name: "file", file: file)
  child.created = Date(timeIntervalSince1970: 9)
  let folder = RawItem(handle: 1, name: "folder", children: [child])
  camera.contents = [folder, RawItem(handle: 8, name: nil)]
  let catalog = access.contents
  #expect(catalog.map(\.kind) == [.folder, .unsupported])
  #expect(catalog[0].children[0].modified == child.created)
  #expect(catalog[1].modified == Date(timeIntervalSince1970: 0))
  child.modified = Date(timeIntervalSince1970: 10)
  #expect(access.contents[0].children[0].modified == child.modified)
  #expect(try await access.read(handle: 7, offset: 1, length: 2) == Data("abc".utf8))
  #expect(file.reads.last?.0 == 1 && file.reads.last?.1 == 2)
  file.bytes = nil
  #expect(try await access.read(handle: 7, offset: 0, length: 1) == nil)
  file.error = RemoteError.posix(EACCES)
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
  camera.contents = nil
  _ = access.contents
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
}

@Test @MainActor func hardwareSessionOpensWaitsForCatalogAndHandlesRemoval() async throws {
  let camera = RawCamera()
  let access: ImageCaptureDeviceAccess
  access = ImageCaptureDeviceAccess(hardware: camera)
  #expect(access.canDelete && access.supportsPTP)
  camera.isLocked = true
  #expect(!access.canDelete)
  camera.isLocked = false
  camera.capabilities = []
  #expect(!access.canDelete && !access.supportsPTP)
  camera.percent = 0
  camera.onPercent = { Task { @MainActor in camera.catalogReady?() } }
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  try await access.open(until: deadline)
  #expect(access.hasOpenSession)
  let result = try await access.command(Data([9]), until: deadline)
  #expect(result.0 == Data([9]) && result.1 == Data([1]))
  await access.close()
  #expect(camera.events == ["start", "open", "close", "stop"])
  await access.close()
  #expect(camera.events.last == "stop")
  camera.onPercent = { Task { @MainActor in camera.removed?() } }
  await #expect(throws: RemoteError.notConnected) { try await access.open(until: deadline) }
  #expect(!access.hasOpenSession)
  await #expect(throws: RemoteError.notConnected) { try await access.open(until: deadline) }
}

@Test @MainActor func hardwareSessionPropagatesFailuresAndNeverDropsFailedDeletionHandles()
  async throws
{
  let camera = RawCamera()
  let access: ImageCaptureDeviceAccess
  access = ImageCaptureDeviceAccess(hardware: camera)
  let file = RawFile()
  camera.contents = [RawItem(handle: 7, name: "file", file: file)]
  _ = access.contents
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  camera.error = RemoteError.posix(EIO)
  await #expect(throws: RemoteError.posix(EIO)) { try await access.open(until: deadline) }
  await #expect(throws: RemoteError.posix(EIO)) {
    try await access.command(Data(), until: deadline)
  }
  await #expect(throws: RemoteError.posix(EIO)) {
    try await access.delete(handles: [7], until: deadline)
  }
  camera.error = nil
  camera.deleteFailed = true
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await access.delete(handles: [7], until: deadline)
  }
  camera.deleteFailed = false
  camera.synchronousDeleteError = true
  await #expect(throws: RemoteError.protocolError) {
    try await access.delete(handles: [7], until: deadline)
  }
  camera.synchronousDeleteError = false
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.delete(handles: [8], until: deadline)
  }
  try await access.delete(handles: [7], until: deadline)
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
  #expect(try RicohHardwareSelection.nativeFiles([]).isEmpty)
  #expect(throws: RemoteError.protocolError) { try RicohHardwareSelection.nativeFiles([file]) }
}

@Test @MainActor func hardwareSessionCloseReleasesCatalogWaitAndClearsFiles() async throws {
  let camera = RawCamera()
  let access: ImageCaptureDeviceAccess
  access = ImageCaptureDeviceAccess(hardware: camera)
  camera.contents = [RawItem(handle: 1, name: "photo", file: RawFile())]
  _ = access.contents
  camera.percent = 0
  camera.onPercent = { Task { @MainActor in await access.close() } }
  await #expect(throws: RemoteError.notConnected) {
    try await access.open(until: .now.advanced(by: .seconds(30)))
  }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 1, offset: 0, length: 1)
  }
  camera.error = RemoteError.posix(EIO)
  camera.hasOpenSession = true
  await access.close()
  #expect(camera.events.last == "stop")
}

@Test @MainActor func ricohCloseFailureStillEndsCatalogWaitAndClearsFileIndex() async throws {
  let camera = RawCamera()
  let access = ImageCaptureDeviceAccess(hardware: camera)
  camera.contents = [RawItem(handle: 1, name: "photo", file: RawFile())]
  _ = access.contents
  camera.percent = 0
  var closing: Task<Void, Never>?
  camera.onPercent = {
    camera.error = NSError(
      domain: NSPOSIXErrorDomain, code: Int(EIO),
      userInfo: [NSLocalizedDescriptionKey: "private-camera-and-path"])
    closing = Task { @MainActor in await access.close() }
  }
  await #expect(throws: RemoteError.notConnected) {
    try await access.open(until: .now.advanced(by: .seconds(15)))
  }
  await closing?.value
  #expect(camera.events.last == "stop")
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 1, offset: 0, length: 1)
  }
}
