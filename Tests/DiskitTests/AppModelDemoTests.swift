import Core
import Foundation
import Testing

@MainActor @Test func appDemoStartsWithIsolatedServicesAndStorage() async throws {
  let options = RuntimeOptions(environment: ["DISKIT_DEMO": "1"])
  let model = AppModel(options: options)
  let other = AppModel(options: options)
  model.start()
  model.start()
  #expect(model.demoSetupError == nil)
  #expect(model.connections.connections.count == 20)
  #expect(
    model.usbDevices.count + model.wirelessDevices.count + model.ricohDevices.count
      + model.cameraUSBDevices.count + model.smbDevices.count == 5)
  #expect(
    !model.connections.connections.contains { $0.params["host"] == model.smbDevices.first?.host })
  #expect(
    !model.connections.connections.contains {
      $0.params["guid"] == model.wirelessDevices.first?.name
    })
  #expect(model.usbDiscovery.devices.isEmpty)
  #expect(model.discovery.devices.isEmpty)
  #expect(model.ricohDiscovery.devices.isEmpty)
  #expect(model.cameraUSBDiscovery.devices.isEmpty)
  #expect(model.wirelessDiscovery.devices.isEmpty)
  try model.secrets.write(Data("test".utf8), for: "demo")
  #expect(try other.secrets.read("demo") == nil)
  model.preferences.set(42, forKey: "test")
  #expect(other.preferences.object(forKey: "test") == nil)
  await #expect(throws: ConnectionError.notImplemented) {
    _ = try await model.remoteProvider(for: Connection(kind: .googleDrive))
  }
  #expect(try await model.oauthProfile(for: Connection(kind: .googleDrive)).nickname == "Demo")
  await model.requestNotificationAuthorization()
  await model.refreshNotificationAuthorization()
  #expect(model.notificationAuthorization == .authorized)
}

@MainActor @Test func emptyDemoDoesNotShowDiscoveredDevices() {
  let model = AppModel(
    options: RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": "empty"]))
  model.start()
  #expect(model.connections.connections.isEmpty)
  #expect(
    model.usbDevices.isEmpty && model.wirelessDevices.isEmpty && model.ricohDevices.isEmpty
      && model.cameraUSBDevices.isEmpty && model.smbDevices.isEmpty)
}
