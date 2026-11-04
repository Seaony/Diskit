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
    guard !CameraIdentity.isGRIV(name) else { return nil }
    self.init(
      id: id, serial: descriptor.serial, name: name.isEmpty ? L("USB 相机") : name,
      vendorID: descriptor.vendorID, productID: descriptor.productID)
  }
}

public enum CameraUSBDiscoveryIssue: Sendable, Equatable {
  case permissionDenied, networkUnavailable, resolutionFailed, failed
}

@MainActor @Observable
public final class CameraUSBDiscovery: NSObject, @preconcurrency ICDeviceBrowserDelegate {
  public private(set) var issue: CameraUSBDiscoveryIssue?
  public private(set) var devices: [CameraUSBDevice] = []
  public var changed: (([CameraUSBDevice]) -> Void)?

  private var browser: ICDeviceBrowser?
  private var running = false
  private var startOverride: (() -> Void)?
  private var stopOverride: (() -> Void)?
  private var waitForTimeout: @Sendable () async throws -> Void = {
    try await Task.sleep(for: .seconds(RemoteTimeout.deviceRequest))
  }
  private var cameras: [String: ICCameraDevice] = [:]
  private var catalog = CameraUSBDeviceCatalog()
  private var enumeration: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?

  public override init() {
    super.init()
  }

  init(
    start: @escaping () -> Void, stop: @escaping () -> Void,
    waitForTimeout: @escaping @Sendable () async throws -> Void
  ) {
    self.startOverride = start
    self.stopOverride = stop
    self.waitForTimeout = waitForTimeout
    super.init()
  }

  public func start() {
    guard !running else { return }
    running = true
    issue = nil
    if let startOverride {
      startOverride()
      return
    }
    let browser = ICDeviceBrowser()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(
      rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    self.browser = browser
    browser.start()
  }

  public func stop() {
    running = false
    stopOverride?()
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
          try await waitForTimeout()
        } catch {
          return
        }
        completeEnumeration(.failure(RemoteError.posix(ETIMEDOUT)))
      }
    }
  }

  func camera(identifier: String) -> ICCameraDevice? {
    guard
      let id = CameraIdentity.selectedID(identifier, devices: devices.map { ($0.id, $0.serial) })
    else { return nil }
    return cameras[id]
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
    publish()
  }

  func add(_ descriptor: CameraUSBDeviceDescriptor) {
    guard catalog.add(descriptor) else { return }
    publish()
  }

  func remove(id: String) {
    catalog.remove(id: id)
    publish()
  }

  private func publish() {
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
    guard
      let id = CameraIdentity.identifier(
        location: UInt32(bitPattern: camera.usbLocationID),
        uuid: camera.uuidString, persistent: camera.persistentIDString)
    else { return nil }
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

  func completeEnumeration(_ result: Result<Void, Error>) {
    guard let enumeration else { return }
    self.enumeration = nil
    if case .failure(let error) = result, !(error is CancellationError) {
      issue = .failed
    }
    timeout?.cancel()
    timeout = nil
    enumeration.resume(with: result)
  }
}
