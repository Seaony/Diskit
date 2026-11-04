import Core
import Foundation
import ImageCaptureCore
import Observation

struct CameraUSBDeviceDescriptor: Sendable, Equatable {
  let id: String
  let serial: String
  let name: String
  let productKind: String
  let transport: String
  let vendorID: Int
  let productID: Int
}

struct CameraUSBDeviceCatalog: Sendable {
  private var values: [String: CameraUSBDevice] = [:]

  var devices: [CameraUSBDevice] {
    values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  @discardableResult
  mutating func add(_ descriptor: CameraUSBDeviceDescriptor) -> Bool {
    guard let device = CameraUSBDevice(descriptor) else { return false }
    values[device.id] = device
    return true
  }

  @discardableResult
  mutating func remove(id: String) -> Bool {
    values.removeValue(forKey: id) != nil
  }
}

extension CameraUSBDevice {
  init?(_ descriptor: CameraUSBDeviceDescriptor) {
    let productKind = descriptor.productKind.trimmingCharacters(in: .whitespacesAndNewlines)
    guard descriptor.transport == ICDeviceTransport.transportTypeUSB.rawValue,
      productKind.caseInsensitiveCompare("Camera") == .orderedSame
    else {
      return nil
    }

    let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return nil }
    let name = descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      id: id, serial: descriptor.serial, name: name.isEmpty ? "USB 相机" : name,
      vendorID: descriptor.vendorID, productID: descriptor.productID)
  }
}

@MainActor @Observable
public final class CameraUSBDiscovery: NSObject, @preconcurrency ICDeviceBrowserDelegate {
  public private(set) var devices: [CameraUSBDevice] = []
  public var changed: (([CameraUSBDevice]) -> Void)?

  private var browser: ICDeviceBrowser?
  private var cameras: [String: ICCameraDevice] = [:]
  private var catalog = CameraUSBDeviceCatalog()
  private var enumeration: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?

  public override init() {
    super.init()
  }

  public func start() {
    guard browser == nil else { return }
    let browser = ICDeviceBrowser()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(
      rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    self.browser = browser
    browser.start()
  }

  public func stop() {
    browser?.stop()
    browser?.delegate = nil
    browser = nil
    cameras.removeAll()
    catalog = CameraUSBDeviceCatalog()
    devices = []
    changed?(devices)
    completeEnumeration(.failure(CancellationError()))
  }

  public static func available() async throws -> [CameraUSBDevice] {
    let discovery = CameraUSBDiscovery()
    defer { discovery.stop() }
    try await discovery.enumerate()
    return discovery.devices
  }

  func enumerate() async throws {
    try await withCheckedThrowingContinuation { continuation in
      enumeration = continuation
      start()
      timeout = Task { @MainActor in
        do {
          try await Task.sleep(for: .seconds(15))
        } catch {
          return
        }
        completeEnumeration(.failure(RemoteError.posix(ETIMEDOUT)))
      }
    }
  }

  func camera(identifier: String) -> ICCameraDevice? {
    cameras.values.first {
      camera in
      guard let device = cameraUSBDevice(camera) else { return false }
      return device.id == identifier || device.serial == identifier
    }
  }

  public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let camera = device as? ICCameraDevice,
      let descriptor = descriptor(for: camera),
      catalog.add(descriptor),
      let model = CameraUSBDevice(descriptor)
    else {
      return
    }
    cameras[model.id] = camera
    devices = catalog.devices
    changed?(devices)
  }

  public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool)
  {
    guard let id = cameras.first(where: { $0.value === device })?.key else { return }
    cameras.removeValue(forKey: id)
    catalog.remove(id: id)
    devices = catalog.devices
    changed?(devices)
  }

  public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
    completeEnumeration(.success(()))
  }

  private func descriptor(for camera: ICCameraDevice) -> CameraUSBDeviceDescriptor? {
    let id =
      camera.uuidString ?? camera.persistentIDString ?? "usb:\(camera.usbLocationID)"
    return CameraUSBDeviceDescriptor(
      id: id,
      serial: camera.serialNumberString ?? "",
      name: camera.name ?? "",
      productKind: camera.productKind ?? "",
      transport: camera.transportType ?? "",
      vendorID: Int(camera.usbVendorID),
      productID: Int(camera.usbProductID))
  }

  private func cameraUSBDevice(_ camera: ICCameraDevice) -> CameraUSBDevice? {
    descriptor(for: camera).flatMap(CameraUSBDevice.init)
  }

  private func completeEnumeration(_ result: Result<Void, Error>) {
    guard let enumeration else { return }
    self.enumeration = nil
    timeout?.cancel()
    timeout = nil
    enumeration.resume(with: result)
  }
}
