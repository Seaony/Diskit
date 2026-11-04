import Foundation
import ImageCaptureCore

@MainActor final class ICRicohFile: RicohHardwareFile {
  let file: ICCameraFile
  init(_ file: ICCameraFile) { self.file = file }
  var size: Int64 { file.fileSize }
  func read(offset: Int64, length: Int64, completion: @escaping @Sendable (Data?, Error?) -> Void) {
    file.requestReadData(atOffset: offset, length: length, completion: completion)
  }
}

@MainActor private final class ICRicohItem: RicohHardwareItem {
  let item: ICCameraItem
  init(_ item: ICCameraItem) { self.item = item }
  var handle: UInt32 { item.ptpObjectHandle }
  var name: String? { item.name }
  var modified: Date? { item.modificationDate }
  var created: Date? { item.creationDate }
  var file: (any RicohHardwareFile)? { (item as? ICCameraFile).map(ICRicohFile.init) }
  var children: [any RicohHardwareItem]? {
    (item as? ICCameraFolder)?.contents?.map(ICRicohItem.init)
  }
}

@MainActor
final class ICRicohCameraHardware: NSObject, RicohCameraHardware,
  @preconcurrency ICCameraDeviceDelegate
{
  private let camera: ICCameraDevice
  private let discovery: RicohDiscovery
  var removed: (@MainActor () -> Void)?
  var catalogReady: (@MainActor () -> Void)?
  init(camera: ICCameraDevice, discovery: RicohDiscovery) {
    self.camera = camera
    self.discovery = discovery
    super.init()
  }
  var hasOpenSession: Bool { camera.hasOpenSession }
  var isLocked: Bool { camera.isLocked }
  var capabilities: [String] { camera.capabilities }
  var catalogPercent: Int { camera.contentCatalogPercentCompleted }
  var contents: [any RicohHardwareItem]? { camera.contents?.map(ICRicohItem.init) }
  func start() {
    discovery.start()
    camera.delegate = self
  }
  func stop() {
    camera.delegate = nil
    discovery.stop()
  }
  func open(completion: @escaping @Sendable (Error?) -> Void) {
    camera.requestOpenSession(options: nil, completion: completion)
  }
  func close(completion: @escaping @Sendable (Error?) -> Void) {
    camera.requestCloseSession(options: nil, completion: completion)
  }
  func command(_ data: Data, completion: @escaping @Sendable (Data, Data, Error?) -> Void) {
    camera.requestSendPTPCommand(data, outData: nil, completion: completion)
  }
  func delete(
    _ files: [any RicohHardwareFile], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void
  ) throws {
    camera.requestDeleteFiles(
      try RicohHardwareSelection.nativeFiles(files), deleteFailed: { _ in failed() }
    ) { _, error in completion(error) }
  }
  func didRemove(_ device: ICDevice) { removed?() }
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { catalogReady?() }
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
