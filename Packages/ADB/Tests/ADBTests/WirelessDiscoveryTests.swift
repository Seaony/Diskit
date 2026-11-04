import Foundation
import Testing

@testable import ADB

@Test func wirelessGUIDMatchesWholeConnectServiceName() {
  let guid = "adb-PixelSerial-Ab12Cd"
  #expect(
    WirelessSelection.matches(guid: guid, service: WirelessDevice(name: guid, type: .connect)))
  #expect(
    !WirelessSelection.matches(guid: guid, service: WirelessDevice(name: guid, type: .pairing)))
  #expect(
    !WirelessSelection.matches(
      guid: guid, service: WirelessDevice(name: guid + "-other", type: .connect)))
  #expect(
    !WirelessSelection.matches(
      guid: guid, service: WirelessDevice(name: "prefix-" + guid, type: .connect)))
  #expect(!WirelessSelection.matches(guid: "", service: WirelessDevice(name: "", type: .connect)))
}

@Test func wirelessGUIDSerialExtractionRequiresAOSPFormat() {
  #expect(WirelessSelection.serial(fromGUID: "adb-PixelSerial-Ab12Cd") == "PixelSerial")
  #expect(
    WirelessSelection.serial(fromGUID: "adb-serial-with-dashes-012AbZ") == "serial-with-dashes")
  #expect(
    WirelessSelection.serial(fromGUID: "adb-serial.1 with spaces-123456") == "serial.1 with spaces")
  for value in [
    "PixelSerial", "adb--Ab12Cd", "adb-serial-short", "adb-serial-1234567", "adb-serial-12345!",
    "adb-serial-123456.local.",
  ] {
    #expect(WirelessSelection.serial(fromGUID: value) == nil)
  }
}

@Test func wirelessSelectionUsesNewPortAfterRediscovery() {
  let guid = "adb-same-Ab12Cd"
  let before = WirelessDevice(name: guid, type: .connect, host: "phone.local.", port: 37001)
  let after = WirelessDevice(name: guid, type: .connect, host: "phone.local.", port: 41234)
  #expect(before.id == after.id)
}

@Test @MainActor func stoppingWirelessDiscoveryClearsPublishedState() {
  let discovery = WirelessDiscovery()
  var reported: [[WirelessDevice]] = []
  discovery.changed = { reported.append($0) }
  discovery.stop()
  #expect(discovery.devices.isEmpty)
  #expect(discovery.error == nil)
  #expect(reported == [[]])
}
