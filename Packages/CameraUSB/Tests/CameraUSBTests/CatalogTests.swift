import Core
import Foundation
import ImageCaptureCore
import Testing

@testable import CameraUSB

private func root(_ items: [CameraCatalogItem]) -> CameraCatalogItem {
  CameraCatalogItem(kind: .folder, name: "Card", handle: 0, children: items)
}
private let photo = CameraCatalogItem(kind: .file, name: "photo.jpg", handle: 7, size: 12)

@Test func cameraCatalogPreservesHierarchyAndRejectsAmbiguity() throws {
  let directory = CameraCatalogItem(kind: .folder, name: "DCIM", handle: 2, children: [photo])
  let snapshot = try CameraCatalog.snapshot([root([directory])])
  #expect(snapshot.entries.map(\.relativePath) == ["DCIM", "DCIM/photo.jpg"])
  #expect(snapshot.entries.last?.fileHandle == 7)
  #expect(snapshot.entries.last?.size == 12)
  #expect(snapshot.storages[0].total == nil)
  for items in [
    [photo, photo], [photo, CameraCatalogItem(kind: .file, name: "other", handle: 7)],
  ] {
    #expect(throws: RemoteError.protocolError) { try CameraCatalog.snapshot([root(items)]) }
  }
  for name in [nil, "", ".", "..", "bad/name", "bad\0name"] as [String?] {
    #expect(throws: RemoteError.protocolError) {
      try CameraCatalog.snapshot([root([CameraCatalogItem(kind: .file, name: name, handle: 9)])])
    }
  }
  #expect(throws: RemoteError.protocolError) {
    try CameraCatalog.snapshot([root([CameraCatalogItem(kind: .file, name: "x", handle: 0)])])
  }
  #expect(throws: RemoteError.unsupported) {
    try CameraCatalog.snapshot([root([CameraCatalogItem(kind: .unsupported, name: "x", handle: 9)])]
    )
  }
  #expect(throws: RemoteError.unsupported) { try CameraCatalog.snapshot([photo]) }
  #expect(throws: RemoteError.protocolError) { try CameraCatalog.snapshot([root([]), root([])]) }
  #expect(
    try CameraCatalog.snapshot([CameraCatalogItem(kind: .folder, name: nil, handle: 4)]).storages[0]
      .id == "4")
  for name in [".", "..", "bad/name", "bad\0name"] {
    #expect(throws: RemoteError.protocolError) {
      try CameraCatalog.snapshot([CameraCatalogItem(kind: .folder, name: name, handle: 4)])
    }
  }
}

@MainActor private final class Session: CameraDeviceSession {
  var available = true
  var isOpen = false
  var catalogReady = false
  var canDelete = true
  var failure: Error?
  var waited = false
  var items = [root([photo])]
  func open(until: ContinuousClock.Instant) async throws {
    if let failure { throw failure }
    isOpen = true
  }
  func waitForCatalog(until: ContinuousClock.Instant) async throws { waited = true }
  func close() async { isOpen = false }
  func catalog() -> [CameraCatalogItem] { items }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    if let failure { throw failure }
    return Data([1, 2])
  }
  func delete(handles: [UInt32], until: ContinuousClock.Instant) async throws {
    if let failure { throw failure }
  }
}

@Test @MainActor func cameraAccessUsesSessionAndRetainsFailures() async throws {
  let session = Session()
  let access = ImageCaptureAccess(session: session)
  await #expect(throws: RemoteError.posix(EIO)) { try await access.snapshot() }
  try await access.open()
  #expect(session.waited)
  _ = try await access.snapshot()
  #expect(try await access.read(handle: 7, offset: 0, length: 2) == Data([1, 2]))
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 9, offset: 0, length: 1)
  }
  await #expect(throws: RemoteError.posix(ENOENT)) { try await access.delete(handles: [9]) }
  session.canDelete = false
  await #expect(throws: RemoteError.posix(EACCES)) { try await access.delete(handles: [7]) }
  session.canDelete = true
  session.failure = CancellationError()
  await #expect(throws: RemoteError.posix(ECANCELED)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
  await #expect(throws: RemoteError.posix(ECANCELED)) { try await access.delete(handles: [7]) }
  session.failure = nil
  try await access.delete(handles: [7])
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
  await access.close()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await access.read(handle: 7, offset: 0, length: 1)
  }
  await #expect(throws: RemoteError.posix(EIO)) { try await access.delete(handles: [7]) }
  session.available = false
  await #expect(throws: RemoteError.posix(EIO)) { try await access.open() }
  session.available = true
  session.failure = RemoteError.posix(EBUSY)
  await #expect(throws: RemoteError.posix(EBUSY)) { try await access.open() }
}

// 开了 USB 调试的手机有 ADB 接口；没开的按安卓厂商识别；都不能当相机列出
@Test func phonesAreNotListedAsCameras() {
  let adb = USBPhoneProbe.Interface(interfaceClass: 0xff, subclass: 0x42, protocolCode: 1)
  let mtp = USBPhoneProbe.Interface(interfaceClass: 6, subclass: 1, protocolCode: 1)
  #expect(USBPhoneProbe.kind(vendorID: 0x2717, interfaces: [mtp, adb]) == .androidWithDebugging)
  #expect(USBPhoneProbe.kind(vendorID: 0x1234, interfaces: [mtp, adb]) == .androidWithDebugging)
  #expect(USBPhoneProbe.kind(vendorID: 0x2717, interfaces: [mtp]) == .androidWithoutDebugging)
  // 索尼相机（0x054c）的 MTP 模式仍然算相机
  #expect(USBPhoneProbe.kind(vendorID: 0x054c, interfaces: [mtp]) == .notPhone)
  for phone in [USBPhoneKind.androidWithDebugging, .androidWithoutDebugging] {
    let descriptor = CameraUSBDeviceDescriptor(
      id: "usb:1", serial: "s", name: "Xiaomi 17", productKind: "Camera",
      transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 0x2717, productID: 0xff48,
      phone: phone)
    #expect(CameraUSBDevice(descriptor) == nil)
  }
}
