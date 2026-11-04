import Core
import Foundation
import ImageCaptureCore
import Observation

public struct RicohDevice: Identifiable, Sendable, Equatable {
  public let id: String
  public let serial: String
  public let name: String
  public init(id: String, serial: String, name: String) {
    self.id = id
    self.serial = serial
    self.name = name
  }
}

public enum RicohDiscoveryIssue: Sendable, Equatable {
  case permissionDenied, networkUnavailable, resolutionFailed, failed
}

@MainActor @Observable
public final class RicohDiscovery: NSObject, @preconcurrency ICDeviceBrowserDelegate {
  public private(set) var issue: RicohDiscoveryIssue?
  public private(set) var devices: [RicohDevice] = []
  public var changed: (([RicohDevice]) -> Void)?
  private var browser: ICDeviceBrowser?
  private var cameras: [String: ICCameraDevice] = [:]
  private var enumeration: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?
  private let startBrowsing: (@MainActor (RicohDiscovery) -> Void)?
  private let stopBrowsing: (@MainActor () -> Void)?
  private var started = false
  public override init() {
    startBrowsing = nil
    stopBrowsing = nil
    super.init()
  }
  init(start: @escaping @MainActor (RicohDiscovery) -> Void, stop: @escaping @MainActor () -> Void)
  {
    startBrowsing = start
    stopBrowsing = stop
    super.init()
  }
  public func start() {
    guard !started else { return }
    started = true
    issue = nil
    if let startBrowsing {
      startBrowsing(self)
      return
    }
    let browser = ICDeviceBrowser()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x101)!
    self.browser = browser
    browser.start()
  }
  public func stop() {
    started = false
    stopBrowsing?()
    browser?.stop()
    browser?.delegate = nil
    browser = nil
    cameras.removeAll()
    devices = []
    changed?(devices)
    completeEnumeration(.failure(CancellationError()))
  }
  public static func available() async throws -> [RicohDevice] {
    let discovery = RicohDiscovery()
    defer { discovery.stop() }
    try await discovery.enumerate()
    return discovery.devices
  }
  func enumerate() async throws {
    try await withCheckedThrowingContinuation { continuation in
      enumeration = continuation
      timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(RemoteTimeout.deviceRequest)) } catch { return }
        self.completeEnumeration(.failure(RemoteError.posix(ETIMEDOUT)))
      }
      start()
    }
  }
  func camera(identifier: String) -> ICCameraDevice? {
    guard
      let id = CameraIdentity.selectedID(identifier, devices: devices.map { ($0.id, $0.serial) })
    else { return nil }
    return cameras[id]
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
  public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let camera = device as? ICCameraDevice,
      camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue
    else {
      return
    }
    let name = camera.name ?? ""
    guard CameraIdentity.isGRIV(name),
      let id = CameraIdentity.identifier(
        location: UInt32(bitPattern: camera.usbLocationID), uuid: camera.uuidString,
        persistent: camera.persistentIDString)
    else { return }
    cameras[id] = camera
    discovered(
      name: name, serial: camera.serialNumberString ?? "",
      location: UInt32(bitPattern: camera.usbLocationID), uuid: camera.uuidString,
      persistent: camera.persistentIDString)
  }
  @discardableResult func discovered(
    name: String, serial: String, location: UInt32, uuid: String?, persistent: String?
  ) -> String? {
    guard CameraIdentity.isGRIV(name),
      let id = CameraIdentity.identifier(location: location, uuid: uuid, persistent: persistent)
    else { return nil }
    devices.removeAll { $0.id == id }
    devices.append(RicohDevice(id: id, serial: serial, name: name))
    devices.sort { $0.name < $1.name }
    changed?(devices)
    return id
  }
  func removed(id: String) {
    cameras.removeValue(forKey: id)
    devices.removeAll { $0.id == id }
    changed?(devices)
  }
  public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool)
  {
    guard let id = cameras.first(where: { $0.value === device })?.key else { return }
    removed(id: id)
  }
  public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
    completeEnumeration(.success(()))
  }
}
