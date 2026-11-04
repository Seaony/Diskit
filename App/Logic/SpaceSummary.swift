import Core
import Foundation

enum SpaceSummary {
  static func mounted(_ available: Int64?) -> String {
    guard let available else { return L("已挂载") }
    return LF("已挂载 · 可用 %@", ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
  }

  static func subtitle(_ space: SpaceInfo) -> String {
    func bytes(_ value: Int64) -> String {
      ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    if let available = space.available {
      return LF("已连接 · 可用 %@", bytes(available))
    }
    if let used = space.used, let total = space.total {
      return LF("已连接 · 已用 %@ / 总容量 %@", bytes(used), bytes(total))
    }
    if let used = space.used {
      return LF("已连接 · 已用 %@", bytes(used))
    }
    if let total = space.total {
      return LF("已连接 · 总容量 %@", bytes(total))
    }
    return L("已连接")
  }
}
