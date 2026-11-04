import Core
import Foundation
import Testing

@testable import ADB

private func configuration(_ descriptors: [UInt8]) -> Data {
  let length = descriptors.count + 9
  return Data([9, 2, UInt8(length), UInt8(length >> 8), 1, 1, 0, 0x80, 50] + descriptors)
}

@Test func usbDescriptorSelectsCurrentAlternateAndMasksPacketBits() throws {
  let data = configuration([
    9, 4, 0, 0, 2, 0xff, 0x42, 1, 0,
    7, 5, 0x81, 2, 0, 2, 0, 7, 5, 1, 2, 0, 2, 0,
    9, 4, 0, 1, 2, 0xff, 0x42, 1, 0,
    7, 5, 0x82, 2, 0, 2, 0, 7, 5, 2, 2, 0, 0x12, 0,
  ])
  #expect(
    try USBBulkEndpoints.parse(data, interface: 0, alternate: 1)
      == USBBulkEndpoints(input: 0x82, output: 2, packetSize: 512))
}

@Test(arguments: [
  [UInt8](), [1, 4], [9, 4, 0, 0, 2, 0xff, 0x42, 1, 0],
  [9, 4, 0, 0, 2, 0xff, 0x42, 1, 0, 7, 5, 0x81, 2, 0, 2, 0, 7, 5, 0x81, 2, 0, 2, 0],
])
func usbDescriptorRejectsMissingTruncatedOrDuplicatePipes(bytes: [UInt8]) {
  #expect(throws: RemoteError.protocolError) {
    try USBBulkEndpoints.parse(configuration(bytes), interface: 0, alternate: 0)
  }
}
