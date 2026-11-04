import Core
import Foundation
import IOKit

extension ADBUSB {
  public static func devices() -> [ADBDevice] { (try? scanDevices()) ?? [] }

  static func scanDevices() throws -> [ADBDevice] {
    let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
    match["bInterfaceClass"] = 0xff
    match["bInterfaceSubClass"] = 0x42
    match["bInterfaceProtocol"] = 1
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
    guard status == KERN_SUCCESS else {
      throw USBTransport.mappedError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
    defer { IOObjectRelease(iterator) }
    var found: [ADBDevice] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      func number(_ key: String) -> Int? {
        (IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, key as CFString, kCFAllocatorDefault, 0) as? NSNumber)?.intValue
      }
      func property(_ key: String) -> String? {
        IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
      }
      let locationID =
        (IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, "locationID" as CFString, kCFAllocatorDefault,
          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber)?
        .uint32Value ?? 0
      var registryID: UInt64 = 0
      IORegistryEntryGetRegistryEntryID(service, &registryID)
      if let device = device(
        interfaceClass: number("bInterfaceClass"), subclass: number("bInterfaceSubClass"),
        protocolCode: number("bInterfaceProtocol"), serial: property("USB Serial Number"),
        name: property("USB Product Name"), registryID: registryID, locationID: locationID)
      {
        found.append(device)
      }
    }
    return found
  }
}
