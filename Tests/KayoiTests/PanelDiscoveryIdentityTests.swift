import Core
import Testing

@Test func unresolvedSMBIsNotHiddenByAnotherMissingHost() {
  let saved = [Connection(kind: .smb, name: "one"), Connection(kind: .s3, name: "cloud")]
  #expect(!PanelDiscoveryIdentity.isSavedSMB(saved, id: "new", host: nil))
  let unrelated = Connection(kind: .s3, name: "other", params: ["host": "nas.local"])
  #expect(!PanelDiscoveryIdentity.isSavedSMB([unrelated], id: "new", host: "nas.local"))
}

@Test func savedBonjourIdentityHidesOnlyItsOwnUnresolvedHost() {
  let saved = Connection(kind: .smb, name: "nas", params: ["bonjourID": "nas-service"])
  #expect(PanelDiscoveryIdentity.isSavedSMB([saved], id: "nas-service", host: nil))
  #expect(!PanelDiscoveryIdentity.isSavedSMB([saved], id: "other-service", host: nil))
}

@Test func stableUSBIdentityWinsOverDuplicateOrEmptySerial() {
  let saved = Connection(kind: .androidUSB, name: "one", params: ["deviceID": "usb:1", "serial": "same"])
  #expect(!PanelDiscoveryIdentity.isSavedDevice([saved], kinds: [.androidUSB], id: "usb:2", serial: "same", serialIsUnique: false))
  #expect(PanelDiscoveryIdentity.isSavedDevice([saved], kinds: [.androidUSB], id: "usb:1", serial: "", serialIsUnique: false))
}

@Test func phoneSavedBySerialIsRecognizedOnAnyUSBPort() {
  let saved = Connection(kind: .androidUSB, name: "phone", params: ["deviceID": "abc", "serial": "abc"])
  #expect(PanelDiscoveryIdentity.isSavedDevice([saved], kinds: [.androidUSB], id: "usb:7", serial: "abc", serialIsUnique: true))
  #expect(!PanelDiscoveryIdentity.isSavedDevice([saved], kinds: [.androidUSB], id: "usb:7", serial: "abc", serialIsUnique: false))
}

@Test func cameraDiscoveryMergesSameUSBLocationWithoutMergingTwoDevicesWithSameSerial() {
  #expect(PanelDiscoveryIdentity.sameCamera(id: "usb:1", serial: "", otherID: "usb:1", otherSerial: ""))
  #expect(!PanelDiscoveryIdentity.sameCamera(id: "usb:1", serial: "same", otherID: "usb:2", otherSerial: "same"))
}
