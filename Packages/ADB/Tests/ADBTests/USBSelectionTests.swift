import Core
import Foundation
import Testing

@testable import ADB

@Test func duplicateUSBSerialRequiresPhysicalSelection() throws {
  let devices = [
    ADBDevice(serial: "same", name: "A", registryID: 1, locationID: 10),
    ADBDevice(serial: "same", name: "B", registryID: 2, locationID: 20),
  ]
  #expect(devices[0].id != devices[1].id)
  #expect(throws: RemoteError.posix(EEXIST)) {
    try ADBUSB.select(params: ["serial": "same"], devices: devices)
  }
  #expect(
    try ADBUSB.select(params: devices[1].connectionParameters(in: devices), devices: devices)
      == devices[1])
  #expect(!ADBUSB.availableIdentifiers(in: devices).contains("same"))
}

@Test func uniqueSerialSurvivesUSBPortChange() throws {
  let old = ADBDevice(serial: "one", name: "A", registryID: 1, locationID: 10)
  let new = ADBDevice(serial: "one", name: "A", registryID: 2, locationID: 20)
  #expect(try ADBUSB.select(params: old.connectionParameters(in: [old]), devices: [new]) == new)
}

@Test func missingUSBSerialUsesPhysicalIdentity() throws {
  let device = ADBDevice(serial: "", name: "A", registryID: 1, locationID: 10)
  #expect(
    try ADBUSB.select(params: device.connectionParameters(in: [device]), devices: [device])
      == device)
  #expect(throws: RemoteError.notConnected) {
    try ADBUSB.select(params: ["deviceID": device.id, "usbLocationID": "20"], devices: [device])
  }
}

private actor FactoryRoutes {
  private(set) var selected: [String] = []
  func record(_ route: String) { selected.append(route) }
}
private struct FactoryTransport: ADBTransport {
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    throw RemoteError.protocolError
  }
  func write(_ data: Data, timeout: TimeInterval) async throws { throw RemoteError.protocolError }
  func close() async {}
}

@Test(arguments: [false, true])
func adbProductionFactoryPrefersOnlyUnambiguousUSB(duplicate: Bool) async throws {
  let device = ADBDevice(serial: "same", name: "A", registryID: 1, locationID: 10)
  let devices =
    duplicate
    ? [device, ADBDevice(serial: "same", name: "B", registryID: 2, locationID: 20)] : [device]
  let routes = FactoryRoutes()
  let connection = Connection(kind: .androidWiFi, params: ["guid": "adb-same-Ab12Cd"])
  _ = try await ADBProviderFactory.make(
    for: connection, devices: { devices },
    usb: { selected in
      await routes.record(selected.id)
      return ADBSession(
        transport: FactoryTransport(), identity: ADBIdentity(store: MemorySecretStore()))
    },
    wireless: { guid in
      await routes.record(guid)
      return ADBSession(
        transport: FactoryTransport(), identity: ADBIdentity(store: MemorySecretStore()))
    },
    server: { ADBServerSession(serial: $0, dial: { throw RemoteError.notConnected }) })
  #expect(await routes.selected == [duplicate ? "adb-same-Ab12Cd" : device.id])
}

@Test func usbCatalogAcceptsOnlyADBInterfacesAndPreservesMissingSerial() {
  #expect(
    ADBUSB.device(
      interfaceClass: 3, subclass: 0x42, protocolCode: 1, serial: "serial", name: nil,
      registryID: 1, locationID: 2) == nil)
  #expect(
    ADBUSB.device(
      interfaceClass: 0xff, subclass: 0x42, protocolCode: 1, serial: nil, name: nil, registryID: 1,
      locationID: 2)?.name == "Android")
  #expect(
    ADBUSB.device(
      interfaceClass: 0xff, subclass: 0x42, protocolCode: 1, serial: "serial", name: nil,
      registryID: 1, locationID: 2)?.name == "serial")
  #expect(
    ADBUSB.device(
      interfaceClass: 0xff, subclass: 0x42, protocolCode: 1, serial: "serial", name: "Phone",
      registryID: 1, locationID: 2)?.name == "Phone")
}

// 厂商自定义类别只写在顶层会一台都匹配不到，必须放在 IOPropertyMatch 里
@Test func adbInterfaceMatchUsesPropertyMatch() throws {
  let match = ADBUSB.adbInterfaceMatch()
  #expect(match["bInterfaceClass"] == nil)
  let properties = try #require(match["IOPropertyMatch"] as? [String: Int])
  #expect(properties == ["bInterfaceClass": 0xff, "bInterfaceSubClass": 0x42, "bInterfaceProtocol": 1])
}
