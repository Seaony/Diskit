import Foundation
import IOKit

// 手机开了文件传输（MTP）或照片传输（PTP）时，系统照片导入服务会把它当相机报上来。
// 按同一个 USB 设备上的接口判断：有 ADB 接口就是开了 USB 调试的手机；
// 厂商是常见安卓手机厂商，就是还没开 USB 调试的手机。只看 MTP 接口不够：部分相机也有 MTP 模式
public enum USBPhoneKind: Sendable, Equatable {
  case notPhone
  case androidWithDebugging
  case androidWithoutDebugging
}

enum USBPhoneProbe {
  // 常见安卓手机厂商的 USB 厂商 ID：小米、谷歌、三星、OPPO/realme/一加、vivo、华为、荣耀、摩托罗拉、魅族、中兴、一加旧款、Nothing
  static let androidVendorIDs: Set<Int> = [
    0x2717, 0x18d1, 0x04e8, 0x22d9, 0x2d95, 0x12d1, 0x339b, 0x22b8, 0x2a45, 0x19d2, 0x2a70, 0x2b0e,
  ]

  struct Interface: Equatable {
    let interfaceClass: Int
    let subclass: Int
    let protocolCode: Int
  }

  static func kind(vendorID: Int, interfaces: [Interface]) -> USBPhoneKind {
    if interfaces.contains(where: { $0.interfaceClass == 0xff && $0.subclass == 0x42 && $0.protocolCode == 1 }) {
      return .androidWithDebugging
    }
    if androidVendorIDs.contains(vendorID) { return .androidWithoutDebugging }
    return .notPhone
  }

  // 读这个位置上的 USB 设备的所有接口；找不到设备时按厂商判断
  static func kind(locationID: UInt32, vendorID: Int) -> USBPhoneKind {
    kind(vendorID: vendorID, interfaces: interfaces(locationID: locationID))
  }

  private static func interfaces(locationID: UInt32) -> [Interface] {
    guard locationID != 0 else { return [] }
    let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
    match[kIOPropertyMatchKey] = ["locationID": locationID]
    let device = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard device != 0 else { return [] }
    defer { IOObjectRelease(device) }
    var children: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(children) }
    var result: [Interface] = []
    while case let child = IOIteratorNext(children), child != 0 {
      defer { IOObjectRelease(child) }
      guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
      func number(_ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(child, key as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber)?.intValue ?? -1
      }
      result.append(
        Interface(
          interfaceClass: number("bInterfaceClass"), subclass: number("bInterfaceSubClass"),
          protocolCode: number("bInterfaceProtocol")))
    }
    return result
  }
}
