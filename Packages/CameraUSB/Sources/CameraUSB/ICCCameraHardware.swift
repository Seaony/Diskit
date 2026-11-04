import Foundation
import ImageCaptureCore

@MainActor private final class ICCCameraItem: CameraHardwareItem {
  let item: ICCameraItem
  init(_ item: ICCameraItem) { self.item = item }
  var name: String? { item.name }
  var handle: UInt32 { item.ptpObjectHandle }
  var size: Int64? { (item as? ICCameraFile)?.fileSize }
  var modified: Date? { item.modificationDate }
  var created: Date? { item.creationDate }
  var isFolder: Bool { item is ICCameraFolder }
  var children: [any CameraHardwareItem]? {
    (item as? ICCameraFolder)?.contents?.map(ICCCameraItem.init)
  }
  func read(offset: Int64, length: Int, completion: @escaping @Sendable (Data?, Error?) -> Void) {
    (item as! ICCameraFile).requestReadData(atOffset: offset, length: Int64(length)) {
      data, error in completion(data, error)
    }
  }
}

@MainActor
final class ICCCameraHardware: NSObject, CameraHardware,
  @preconcurrency ICCameraDeviceDelegate
{
  private let camera: ICCameraDevice
  private let discovery: CameraUSBDiscovery
  var removed: (() -> Void)?
  var ready: (() -> Void)?
  var isOpen: Bool { camera.hasOpenSession }
  var catalogProgress: Int { Int(camera.contentCatalogPercentCompleted) }
  var locked: Bool { camera.isLocked }
  var deleteSupported: Bool {
    camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
  }
  var contents: [any CameraHardwareItem]? { camera.contents?.map(ICCCameraItem.init) }
  init(camera: ICCameraDevice, discovery: CameraUSBDiscovery) {
    self.camera = camera
    self.discovery = discovery
    super.init()
  }
  func start() {
    discovery.start()
    camera.delegate = self
  }
  func stop() {
    camera.delegate = nil
    discovery.stop()
  }
  func open(completion: @escaping @Sendable (Error?) -> Void) {
    camera.requestOpenSession(options: nil) { completion($0) }
  }
  func close(completion: @escaping @Sendable (Error?) -> Void) {
    camera.requestCloseSession(options: nil) { completion($0) }
  }
  func delete(
    _ items: [any CameraHardwareItem], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void
  ) {
    let files = items.map { ($0 as! ICCCameraItem).item as! ICCameraFile }
    camera.requestDeleteFiles(files, deleteFailed: { _ in failed() }) { _, error in
      completion(error)
    }
  }
  func didRemove(_ device: ICDevice) { removed?() }
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { ready?() }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
    error: Error?
  ) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem, error: Error?
  ) {}
  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}
