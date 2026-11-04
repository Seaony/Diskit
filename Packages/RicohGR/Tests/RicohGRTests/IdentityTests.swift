import Core
import Testing

@testable import RicohGR

@Test func cameraIdentityRejectsAmbiguousSerialAndSupportsMissingSerial() {
  let devices = [
    (id: "usb:1", serial: "same"), (id: "usb:2", serial: "same"), (id: "usb:3", serial: ""),
  ]
  #expect(CameraIdentity.selectedID("same", devices: devices) == nil)
  #expect(CameraIdentity.selectedID("usb:3", devices: devices) == "usb:3")
  #expect(CameraIdentity.selectedID("", devices: devices) == nil)
  #expect(CameraIdentity.selectedID("same", devices: [devices[0]]) == "usb:1")
  #expect(CameraIdentity.identifier(location: 3, uuid: "duplicate", persistent: nil) == "usb:3")
  #expect(CameraIdentity.identifier(location: 0, uuid: " ", persistent: "stable") == "stable")
}

@Test func cameraGRIVBoundaryExcludesOtherModels() {
  #expect(CameraIdentity.isGRIV(" Ricoh  GR IV "))
  #expect(!CameraIdentity.isGRIV("RICOH GR III"))
  #expect(!CameraIdentity.isGRIV("GR IVx"))
  #expect(!CameraIdentity.isGRIV("Other GR IV Camera"))
}
