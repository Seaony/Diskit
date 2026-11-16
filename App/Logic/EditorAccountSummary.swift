import Core
import Foundation

enum EditorAccountSummary {
  // 不知道容量时返回 nil，界面上就不显示这一行
  static func text(_ space: SpaceInfo) -> String? {
    func bytes(_ value: Int64) -> String {
      ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    if let used = space.used, let total = space.total {
      return LF("已用 %@ / 总容量 %@", bytes(used), bytes(total))
    }
    if let available = space.available { return LF("可用 %@", bytes(available)) }
    if let used = space.used { return LF("已用 %@", bytes(used)) }
    if let total = space.total { return LF("总容量 %@", bytes(total)) }
    return nil
  }

  // 编辑已保存的位置时，沿用卡片上已经知道的容量，不另外联网去查
  static func knownSpace(_ state: ConnectionState?) -> SpaceInfo? {
    switch state {
    case .tested(let space): space
    case .mounted(let mount): mount.availableBytes.map { SpaceInfo(total: nil, used: nil, available: $0) }
    default: nil
    }
  }
}
