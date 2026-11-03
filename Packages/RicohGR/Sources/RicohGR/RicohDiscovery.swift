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

@MainActor @Observable
public final class RicohDiscovery: NSObject, @preconcurrency ICDeviceBrowserDelegate {
  public private(set) var devices: [RicohDevice] = []
  public var changed: (([RicohDevice]) -> Void)?
  private var browser: ICDeviceBrowser?
  private var cameras: [String: ICCameraDevice] = [:]
  private var enumeration: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?
  public override init() { super.init() }
  public func start() {
    guard browser == nil else { return }
    let browser = ICDeviceBrowser()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x101)!
    self.browser = browser
    browser.start()
  }
  public func stop() {
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
      start()
      timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        self.completeEnumeration(.failure(RemoteError.posix(ETIMEDOUT)))
      }
    }
  }
  func camera(serial: String) -> ICCameraDevice? {
    cameras.values.first { $0.serialNumberString == serial }
  }
  private func completeEnumeration(_ result: Result<Void, Error>) {
    guard let enumeration else { return }
    self.enumeration = nil
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
    let normalized = name.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard normalized.contains("RICOH GR") || normalized.contains("GR IV") else { return }
    let serial = camera.serialNumberString ?? ""
    let id = camera.uuidString ?? "usb:\(camera.usbLocationID)"
    cameras[id] = camera
    devices.removeAll { $0.id == id }
    devices.append(RicohDevice(id: id, serial: serial, name: name))
    devices.sort { $0.name < $1.name }
    changed?(devices)
  }
  public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool)
  {
    guard let id = cameras.first(where: { $0.value === device })?.key else { return }
    cameras.removeValue(forKey: id)
    devices.removeAll { $0.id == id }
    changed?(devices)
  }
  public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
    completeEnumeration(.success(()))
  }
}
