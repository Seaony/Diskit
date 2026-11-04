import Core
import Foundation
import Testing

@testable import ADB

@MainActor private final class TestUSBDiscovery: USBDiscoverySource {
  var callbacks: [@MainActor () -> Void] = []
  var listed: [ADBDevice] = []
  var startError: (any Error)?
  var scanError: (any Error)?
  var stops = 0
  func start(changed: @escaping @MainActor () -> Void) throws {
    if let startError { throw startError }
    callbacks.append(changed)
  }
  func devices() throws -> [ADBDevice] {
    if let scanError { throw scanError }
    return listed
  }
  func stop() { stops += 1 }
}

@Test @MainActor func usbDiscoveryPublishesHotplugAndRejectsLateCallbacks() {
  let source = TestUSBDiscovery()
  let discovery = USBDiscovery(source: source)
  var updates: [[ADBDevice]] = []
  discovery.changed = { updates.append($0) }
  discovery.start()
  discovery.start()
  #expect(source.callbacks.count == 1)
  let device = ADBDevice(serial: "", name: "Phone", registryID: 5, locationID: 42)
  source.listed = [device]
  source.callbacks[0]()
  #expect(discovery.devices == [device])
  discovery.stop()
  discovery.stop()
  #expect(discovery.devices.isEmpty)
  #expect(source.stops == 1)
  source.callbacks[0]()
  #expect(discovery.devices.isEmpty)
  discovery.start()
  source.listed = []
  source.callbacks[0]()
  #expect(discovery.devices == [device])
  source.callbacks[1]()
  #expect(discovery.devices.isEmpty)
  #expect(updates.count == 5)
}

@Test @MainActor func usbDiscoveryReportsPermissionAndRecoversAfterRetry() {
  let source = TestUSBDiscovery()
  source.startError = RemoteError.posix(EACCES)
  let discovery = USBDiscovery(source: source)
  discovery.start()
  #expect(discovery.issue == .permissionDenied)
  source.startError = nil
  source.scanError = RemoteError.posix(EIO)
  discovery.start()
  #expect(discovery.issue == .failed)
  source.scanError = nil
  source.callbacks.last?()
  #expect(discovery.issue == nil)
}

@Test @MainActor func usbDiscoveryReleasesMonitorWhenOwnerDisappears() {
  let source = TestUSBDiscovery()
  var discovery: USBDiscovery? = USBDiscovery(source: source)
  discovery?.start()
  discovery = nil
  #expect(source.stops == 1)
}
