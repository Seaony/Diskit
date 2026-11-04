import Core

struct HelpCapability: Identifiable {
  enum Availability {
    case supported, unavailable, deviceDependent
    var title: String {
      switch self {
      case .supported: L("支持")
      case .unavailable: L("不支持")
      case .deviceDependent: L("取决于设备")
      }
    }
    var symbol: String {
      switch self {
      case .supported: "checkmark"
      case .unavailable: "minus"
      case .deviceDependent: "questionmark.circle"
      }
    }
  }
  let id: String
  let title: String
  let availability: Availability
  init(_ id: String, _ title: String, _ availability: Availability) {
    self.id = id
    self.title = title
    self.availability = availability
  }
}
