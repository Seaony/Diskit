import Core
import Foundation

public struct ADBDevice: Identifiable, Sendable, Equatable {
  public var id: String { locationID == 0 ? "usb-registry:\(registryID)" : "usb:\(locationID)" }
  public let serial: String
  public let name: String
  public let registryID: UInt64
  public let locationID: UInt32
  public init(serial: String, name: String, registryID: UInt64, locationID: UInt32 = 0) {
    self.serial = serial
    self.name = name
    self.registryID = registryID
    self.locationID = locationID
  }
  public func connectionParameters(in devices: [ADBDevice]) -> [String: String] {
    if !serial.isEmpty, devices.filter({ $0.serial == serial }).count == 1 {
      return ["serial": serial, "deviceID": serial]
    }
    var params = ["serial": serial, "deviceID": id]
    if locationID != 0 { params["usbLocationID"] = String(locationID) }
    return params
  }
}

public enum ADBUSB {
  static func device(
    interfaceClass: Int?, subclass: Int?, protocolCode: Int?, serial: String?, name: String?,
    registryID: UInt64, locationID: UInt32
  ) -> ADBDevice? {
    guard interfaceClass == 0xff, subclass == 0x42, protocolCode == 1 else { return nil }
    let serial = serial ?? ""
    return ADBDevice(
      serial: serial, name: name ?? (serial.isEmpty ? "Android" : serial),
      registryID: registryID, locationID: locationID)
  }

  public static func availableIdentifiers(in devices: [ADBDevice]) -> Set<String> {
    var result = Set(devices.map(\.id))
    for device in devices where !device.serial.isEmpty {
      if devices.filter({ $0.serial == device.serial }).count == 1 { result.insert(device.serial) }
    }
    return result
  }

  static func select(params: [String: String], devices: [ADBDevice]) throws -> ADBDevice {
    let serial = params["serial"] ?? ""
    let matches: [ADBDevice]
    if let location = params["usbLocationID"] {
      guard let value = UInt32(location), value != 0 else { throw RemoteError.invalidPath }
      matches = devices.filter { $0.locationID == value && (serial.isEmpty || $0.serial == serial) }
    } else if let id = params["deviceID"], id != serial {
      matches = devices.filter { $0.id == id && (serial.isEmpty || $0.serial == serial) }
    } else {
      guard !serial.isEmpty else { throw RemoteError.invalidPath }
      matches = devices.filter { $0.serial == serial }
    }
    guard matches.count < 2 else { throw RemoteError.posix(EEXIST) }
    guard let device = matches.first else { throw RemoteError.notConnected }
    return device
  }

}
