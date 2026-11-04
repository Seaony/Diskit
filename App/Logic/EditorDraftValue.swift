import Core

enum EditorDraftValue {
  static func value(
    _ field: String, draft: Connection, pairingID: String, pairingCode: String, password: String
  ) -> String {
    switch field {
    case "name": draft.name
    case "device": draft.params["deviceID"] ?? draft.params["serial"] ?? ""
    case "pairingID": pairingID
    case "pairingCode": pairingCode.count == 6 ? pairingCode : ""
    case "password": password
    default: draft.params[field] ?? ""
    }
  }
}
