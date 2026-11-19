import Core
import Foundation
import Testing

@testable import CameraUSB

@MainActor private final class HardwareItem: CameraHardwareItem {
  var name: String? = "photo"
  var handle: UInt32 = 1
  var size: Int64? = 2
  var modified: Date?
  var created: Date?
  var isFolder = false
  var children: [any CameraHardwareItem]?
  var data: Data? = Data([1, 2])
  var failure: Error?
  func read(offset: Int64, length: Int, completion: @escaping @Sendable (Data?, Error?) -> Void) {
    completion(data, failure)
  }
}
@MainActor private final class Hardware: CameraHardware {
  var isOpen = false
  var catalogProgress = 0
  var locked = false
  var deleteSupported = true
  var contents: [any CameraHardwareItem]? = []
  var removed: (() -> Void)?
  var ready: (() -> Void)? {
    didSet { onReadyInstalled?() }
  }
  var onReadyInstalled: (() -> Void)?
  var failure: Error?
  var deleteFailed = false
  var stopped = false
  func start() {}
  func stop() { stopped = true }
  func open(completion: @escaping @Sendable (Error?) -> Void) {
    isOpen = true
    completion(failure)
  }
  func close(completion: @escaping @Sendable (Error?) -> Void) {
    isOpen = false
    completion(failure)
  }
  func delete(
    _ items: [any CameraHardwareItem], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void
  ) {
    if deleteFailed { failed() } else { completion(failure) }
  }
}

@Test @MainActor func cameraNativeSessionProjectsRawItemsAndControlsIndex() async throws {
  let hardware = Hardware()
  let photo = HardwareItem()
  let folder = HardwareItem()
  folder.isFolder = true
  folder.name = "Card"
  folder.size = nil
  folder.children = [photo]
  hardware.contents = [folder]
  let session = NativeCameraSession(camera: hardware)
  #expect(!session.isOpen && !session.catalogReady && session.canDelete)
  hardware.locked = true
  #expect(!session.canDelete)
  hardware.locked = false
  hardware.deleteSupported = false
  #expect(!session.canDelete)
  hardware.catalogProgress = 100
  #expect(session.catalogReady)
  try await session.open(until: .now.advanced(by: .seconds(15)))
  let items = session.catalog()
  #expect(items[0].kind == .folder && items[0].children[0].kind == .file)
  #expect(items[0].children[0].modified == Date(timeIntervalSince1970: 0))
  #expect(try await session.read(handle: 1, offset: 0, length: 2) == Data([1, 2]))
  photo.data = nil
  await #expect(throws: RemoteError.failed(EIO, L("相机没有返回数据，也没有报错"))) {
    try await session.read(handle: 1, offset: 0, length: 2)
  }
  photo.failure = RemoteError.posix(ETIMEDOUT)
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) {
    try await session.read(handle: 1, offset: 0, length: 2)
  }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await session.delete(handles: [9], until: .now.advanced(by: .seconds(15)))
  }
  hardware.deleteFailed = true
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await session.delete(handles: [1], until: .now.advanced(by: .seconds(15)))
  }
  hardware.deleteFailed = false
  hardware.failure = RemoteError.posix(EBUSY)
  await #expect(throws: RemoteError.posix(EBUSY)) {
    try await session.delete(handles: [1], until: .now.advanced(by: .seconds(15)))
  }
  hardware.failure = nil
  try await session.delete(handles: [1], until: .now.advanced(by: .seconds(15)))
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await session.read(handle: 1, offset: 0, length: 2)
  }
  await session.close()
  #expect(hardware.stopped && !session.isOpen)
  await session.close()
  photo.size = nil
  photo.children = nil
  photo.created = Date(timeIntervalSince1970: 2)
  hardware.contents = [photo]
  #expect(session.catalog()[0].kind == .unsupported)
  #expect(session.catalog()[0].modified == photo.created)
  photo.modified = Date(timeIntervalSince1970: 3)
  #expect(session.catalog()[0].modified == photo.modified)
  hardware.removed?()
  #expect(!session.available)
  hardware.ready?()
  hardware.contents = nil
  #expect(session.catalog().isEmpty)
  folder.children = nil
  hardware.contents = [folder]
  #expect(session.catalog()[0].kind == .folder)
  #expect(session.catalog()[0].children.isEmpty)
}

@Test @MainActor func cameraNativeCatalogWaitCompletesOnReadyAndRemoval() async throws {
  let hardware = Hardware()
  let session = NativeCameraSession(camera: hardware)
  hardware.onReadyInstalled = { [weak hardware] in hardware?.ready?() }
  try await session.waitForCatalog(until: .now.advanced(by: .seconds(15)))
  hardware.onReadyInstalled = { [weak hardware] in hardware?.removed?() }
  await #expect(throws: RemoteError.failed(EIO, L("相机在加载目录时被拔出或断开"))) {
    try await session.waitForCatalog(until: .now.advanced(by: .seconds(15)))
  }
  #expect(!session.available)
}

@Test @MainActor func cameraCloseFailureStillEndsCatalogWaitAndClearsFileIndex() async throws {
  let hardware = Hardware()
  hardware.isOpen = true
  hardware.contents = [HardwareItem()]
  let session = NativeCameraSession(camera: hardware)
  _ = session.catalog()
  hardware.failure = NSError(
    domain: NSPOSIXErrorDomain, code: Int(EIO),
    userInfo: [NSLocalizedDescriptionKey: "private-camera-and-path"])
  var closing: Task<Void, Never>?
  hardware.onReadyInstalled = { closing = Task { @MainActor in await session.close() } }
  await #expect(throws: RemoteError.failed(EIO, L("相机目录还没加载完，连接就被关闭了"))) {
    try await session.waitForCatalog(until: .now.advanced(by: .seconds(15)))
  }
  await closing?.value
  #expect(hardware.stopped)
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await session.read(handle: 1, offset: 0, length: 1)
  }
}
