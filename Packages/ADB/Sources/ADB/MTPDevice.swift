import Core
import Foundation
import IOKit

// 开着“文件传输（MTP）”的安卓设备：手机、平板、阅读器都算，不需要打开 USB 调试
public struct MTPDevice: Identifiable, Sendable, Equatable {
  public var id: String { locationID == 0 ? "mtp-registry:\(registryID)" : "mtp:\(locationID)" }
  public let serial: String
  public let name: String
  // USB 描述符里的产品名（如“LAGOON-MTP _SN:…”）；问到型号前 name 就是它
  public private(set) var productName: String
  // MTP 接口在系统注册表里的编号，打开接口用
  public let registryID: UInt64
  public let locationID: UInt32
  // 同一台设备还开着 USB 调试；这时优先走 ADB，速度和路径都更好
  public let hasADB: Bool
  public init(
    serial: String, name: String, registryID: UInt64, locationID: UInt32 = 0, hasADB: Bool = false
  ) {
    self.serial = serial
    self.name = name
    productName = name
    self.registryID = registryID
    self.locationID = locationID
    self.hasADB = hasADB
  }
  func named(_ model: String) -> MTPDevice {
    var device = MTPDevice(
      serial: serial, name: model, registryID: registryID, locationID: locationID, hasADB: hasADB)
    device.productName = productName
    return device
  }
  public func connectionParameters(in devices: [MTPDevice]) -> [String: String] {
    if !serial.isEmpty, devices.filter({ $0.serial == serial }).count == 1 {
      return ["serial": serial, "deviceID": serial]
    }
    var params = ["serial": serial, "deviceID": id]
    if locationID != 0 { params["usbLocationID"] = String(locationID) }
    return params
  }
}

public enum MTPUSB {
  // 常见安卓设备厂商的 USB 厂商 ID：小米、谷歌、三星、OPPO/realme/一加、vivo、华为、荣耀、摩托罗拉、魅族、中兴、一加旧款、Nothing、
  // LG、HTC、索尼手机、亚马逊、华硕、联想
  static let androidVendorIDs: Set<Int> = [
    0x2717, 0x18d1, 0x04e8, 0x22d9, 0x2d95, 0x12d1, 0x339b, 0x22b8, 0x2a45, 0x19d2, 0x2a70, 0x2b0e,
    0x1004, 0x0bb4, 0x0fce, 0x1949, 0x0b05, 0x17ef,
  ]

  struct Interface: Equatable {
    let interfaceClass: Int
    let subclass: Int
    let protocolCode: Int
    let name: String
  }

  // 安卓的文件传输接口有两种写法：厂商自定义类别（0xFF/0xFF）且接口名是“MTP”（Android 系统默认）；
  // 或标准相机类（6/1/1），这时只认安卓厂商：真相机也用这个类别，已经在“相机”里列着，不能再按安卓设备提醒一遍
  static func isMTP(_ interface: Interface, vendorID: Int) -> Bool {
    if interface.interfaceClass == 0xff, interface.subclass == 0xff,
      interface.name.uppercased().contains("MTP")
    {
      return true
    }
    return interface.interfaceClass == 6 && interface.subclass == 1 && interface.protocolCode == 1
      && androidVendorIDs.contains(vendorID)
  }

  static func isADB(_ interface: Interface) -> Bool {
    interface.interfaceClass == 0xff && interface.subclass == 0x42 && interface.protocolCode == 1
  }

  public static func devices() -> [MTPDevice] { (try? scanDevices()) ?? [] }

  // 有没有 USB 接口正被 Android File Transfer 独占（注册表里的占用者名字被截成“pid N, Android File Tra”）
  public static func heldByAndroidFileTransfer() -> Bool {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS
    else { return false }
    defer { IOObjectRelease(iterator) }
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { return false }
      defer { IOObjectRelease(service) }
      let owner = IORegistryEntryCreateCFProperty(
        service, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
      if owner?.contains("Android File") == true { return true }
    }
  }

  // 遍历所有 USB 接口，按所属设备（locationID）分组后判断
  static func scanDevices() throws -> [MTPDevice] {
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
    guard status == KERN_SUCCESS else {
      throw USBTransport.mappedError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
    defer { IOObjectRelease(iterator) }
    struct Candidate {
      var mtp: (registryID: UInt64, serial: String, name: String)?
      var hasADB = false
    }
    var groups: [UInt32: Candidate] = [:]
    var order: [UInt32] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      func number(_ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber)?.intValue ?? -1
      }
      // 序列号、产品名在上一层的设备节点上
      func inherited(_ key: String) -> String? {
        IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
      }
      let interface = Interface(
        interfaceClass: number("bInterfaceClass"), subclass: number("bInterfaceSubClass"),
        protocolCode: number("bInterfaceProtocol"),
        name: (IORegistryEntryCreateCFProperty(service, "kUSBString" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? String) ?? "")
      let vendorID = number("idVendor")
      let location = UInt32(truncatingIfNeeded: number("locationID"))
      let adb = isADB(interface)
      let mtp = isMTP(interface, vendorID: vendorID)
      guard adb || mtp else { continue }
      if groups[location] == nil { order.append(location) }
      var candidate = groups[location] ?? Candidate()
      if adb { candidate.hasADB = true }
      if mtp, candidate.mtp == nil {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let serial = inherited("USB Serial Number") ?? ""
        let name = inherited("USB Product Name") ?? ""
        candidate.mtp = (registryID, serial, name.isEmpty ? "Android" : name)
      }
      groups[location] = candidate
    }
    return order.compactMap { location in
      guard let candidate = groups[location], let mtp = candidate.mtp else { return nil }
      return MTPDevice(
        serial: mtp.serial, name: mtp.name, registryID: mtp.registryID, locationID: location,
        hasADB: candidate.hasADB)
    }
  }

  // 问设备自己的型号名（如“Leaf5”）：USB 描述符里的产品名常是内部代号（“LAGOON-MTP _SN:…”）。
  // 不用开会话；接口被别的程序占着或设备 3 秒内不答就返回 nil
  static func model(of device: MTPDevice) async -> String? {
    guard let channel = try? SystemUSBChannel(registryID: device.registryID, role: .mtp) else {
      return nil
    }
    let session = MTPSession(channel: channel, readTimeout: 3)
    await session.reset()
    let info = try? await session.deviceInfo(commandTimeout: 3)
    await session.close()
    guard let info else { return nil }
    let model = info.model.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.isEmpty ? nil : model
  }

  public static func availableIdentifiers(in devices: [MTPDevice]) -> Set<String> {
    var result = Set(devices.map(\.id))
    for device in devices where !device.serial.isEmpty {
      if devices.filter({ $0.serial == device.serial }).count == 1 { result.insert(device.serial) }
    }
    return result
  }

  public static func select(params: [String: String], devices: [MTPDevice]) throws -> MTPDevice {
    let serial = params["serial"] ?? ""
    let matches: [MTPDevice]
    if let location = params["usbLocationID"] {
      guard let value = UInt32(location), value != 0 else { throw RemoteError.invalidPath }
      matches = devices.filter { $0.locationID == value && $0.serial == serial }
    } else if let id = params["deviceID"], id != serial {
      matches = devices.filter { $0.id == id && $0.serial == serial }
    } else {
      guard !serial.isEmpty else { throw RemoteError.invalidPath }
      matches = devices.filter { $0.serial == serial }
    }
    guard matches.count < 2 else { throw RemoteError.posix(EEXIST) }
    guard let device = matches.first else { throw RemoteError.notConnected }
    return device
  }
}
