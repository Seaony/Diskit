import Foundation
import ImageCaptureCore
import Testing

@testable import CameraUSB

@Test func discoveryKeepsOnlyLocalUSBCamerasAndHandlesRemoval() throws {
  var catalog = CameraUSBDeviceCatalog()
  let camera = CameraUSBDeviceDescriptor(
    id: "canon-1", serial: "serial-1", name: "Canon EOS", productKind: "Camera",
    transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 1, productID: 2)
  let phone = CameraUSBDeviceDescriptor(
    id: "phone-1", serial: "phone", name: "My Phone", productKind: "iPhone",
    transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 3, productID: 4)
  let networkCamera = CameraUSBDeviceDescriptor(
    id: "network-1", serial: "network", name: "Network Camera", productKind: "Camera",
    transport: ICDeviceTransport.transportTypeTCPIP.rawValue, vendorID: 5, productID: 6)

  let addedCamera = catalog.add(camera)
  let addedPhone = catalog.add(phone)
  let addedNetworkCamera = catalog.add(networkCamera)
  #expect(addedCamera)
  #expect(!addedPhone)
  #expect(!addedNetworkCamera)
  #expect(
    catalog.devices == [
      CameraUSBDevice(
        id: "canon-1", serial: "serial-1", name: "Canon EOS", vendorID: 1, productID: 2)
    ])
  let removedCamera = catalog.remove(id: "canon-1")
  #expect(removedCamera)
  #expect(catalog.devices.isEmpty)
}

@Test func discoveryRejectsMissingIdentityAndUpdatesKnownDevice() throws {
  var catalog = CameraUSBDeviceCatalog()
  let missingID = CameraUSBDeviceDescriptor(
    id: " ", serial: "", name: "Camera", productKind: "Camera",
    transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 1, productID: 2)
  let addedMissingID = catalog.add(missingID)
  #expect(!addedMissingID)

  let first = CameraUSBDeviceDescriptor(
    id: "camera", serial: "serial", name: "Older Name", productKind: "Camera",
    transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 7, productID: 8)
  let updated = CameraUSBDeviceDescriptor(
    id: "camera", serial: "serial", name: "New Name", productKind: "Camera",
    transport: ICDeviceTransport.transportTypeUSB.rawValue, vendorID: 7, productID: 8)
  let addedFirst = catalog.add(first)
  let addedUpdated = catalog.add(updated)
  #expect(addedFirst)
  #expect(addedUpdated)
  #expect(catalog.devices.map(\.name) == ["New Name"])
}
