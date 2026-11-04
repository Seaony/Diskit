import Core
import Foundation
import IOKit
import Testing

@testable import ADB

@Test func usbErrorsKeepTheirPOSIXMeaning() {
  let cases: [(Int32, Int32)] = [
    (kIOReturnBusy, EBUSY), (kIOReturnExclusiveAccess, EBUSY),
    (kIOReturnNotPrivileged, EACCES), (kIOReturnNotPermitted, EACCES),
    (kIOReturnNoDevice, ENODEV), (kIOReturnTimeout, ETIMEDOUT), (kIOReturnError, EIO),
  ]
  for (native, expected) in cases {
    let result = USBTransport.mappedError(NSError(domain: "IOKit", code: Int(native))) as NSError
    #expect(result.domain == NSPOSIXErrorDomain)
    #expect(result.code == Int(expected))
  }
  #expect(USBTransport.mappedError(CancellationError()) is CancellationError)
  let preserved = USBTransport.mappedError(POSIXError(.ENOMEM)) as NSError
  #expect(preserved.code == Int(ENOMEM))
  #expect(preserved.domain == NSPOSIXErrorDomain)
}
