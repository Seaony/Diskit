import Core
import Foundation

enum PanelDiscoveryIdentity {
  static func isSavedSMB(_ saved: [Connection], id: String, host: String?) -> Bool {
    saved.contains { connection in
      guard connection.kind == .smb else { return false }
      return connection.params["bonjourID"] == id
        || (host != nil && connection.params["host"] == host)
    }
  }

  static func isSavedDevice(_ saved: [Connection], kinds: Set<ConnectionKind>, id: String, serial: String, serialIsUnique: Bool) -> Bool {
    saved.contains { connection in
      guard kinds.contains(connection.kind) else { return false }
      // 安卓手机序列号唯一时 deviceID 存的就是序列号
      if let savedID = connection.params["deviceID"], !savedID.isEmpty {
        return savedID == id || (serialIsUnique && !serial.isEmpty && savedID == serial)
      }
      return serialIsUnique && !serial.isEmpty && connection.params["serial"] == serial
    }
  }

  static func sameCamera(id: String, serial: String, otherID: String, otherSerial: String) -> Bool {
    if id.hasPrefix("usb:"), otherID.hasPrefix("usb:") { return id == otherID }
    return id == otherID || (!serial.isEmpty && serial == otherSerial)
  }
}
