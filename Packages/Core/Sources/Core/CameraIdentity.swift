import Foundation

public enum CameraIdentity {
  public static func identifier(location: UInt32, uuid: String?, persistent: String?) -> String? {
    if location != 0 { return "usb:\(location)" }
    return [uuid, persistent].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  public static func selectedID(_ identifier: String, devices: [(id: String, serial: String)])
    -> String?
  {
    guard !identifier.isEmpty else { return nil }
    if devices.contains(where: { $0.id == identifier }) { return identifier }
    let matches = devices.filter { !$0.serial.isEmpty && $0.serial == identifier }
    return matches.count == 1 ? matches[0].id : nil
  }

  public static func isGRIV(_ name: String) -> Bool {
    let name = name.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return name == "GR IV" || name == "RICOH GR IV"
  }
}
