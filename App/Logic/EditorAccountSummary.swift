import Core
import Foundation

enum EditorAccountSummary {
  static func text(_ space: SpaceInfo) -> String {
    func bytes(_ value: Int64) -> String {
      ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    if let used = space.used, let total = space.total {
      return LF("已用 %@ / 总容量 %@", bytes(used), bytes(total))
    }
    if let available = space.available { return LF("可用 %@", bytes(available)) }
    if let used = space.used { return LF("已用 %@", bytes(used)) }
    if let total = space.total { return LF("总容量 %@", bytes(total)) }
    return L("容量暂不可用")
  }
}
