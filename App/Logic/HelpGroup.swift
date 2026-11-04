import Core

enum HelpGroup: String, CaseIterable, Identifiable {
  case devices, network, cloud, experimental, objectStorage
  var id: String { rawValue }
  var title: String {
    switch self {
    case .devices: L("设备")
    case .network: L("局域网共享")
    case .cloud: L("网盘")
    case .experimental: L("实验性网盘")
    case .objectStorage: L("对象存储")
    }
  }
}
