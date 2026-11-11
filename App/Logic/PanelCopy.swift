import Core
import Foundation

enum PanelCopy {
  // 面板只列已保存的位置；已发现的设备在添加窗口里。读不到列表时显示错误而不是空状态
  static func showsEmptyState(savedCount: Int, hasLoadError: Bool) -> Bool {
    savedCount == 0 && !hasLoadError
  }

  static func subtitle(_ state: ConnectionState, kind: ConnectionKind) -> String {
    switch state {
    case .needsLogin: L("登录已过期")
    case .disconnected: L("未连接")
    case .unavailable:
      switch kind {
      case .androidUSB, .androidWiFi: L("手机未连接")
      case .ricohGR, .cameraUSB: L("相机未连接")
      default: L("设备或服务已断开")
      }
    case .awaitingAuthorization: L("请在手机上点“允许 USB 调试”")
    case .ejecting: L("正在推出…")
    case .connecting: L("正在连接…")
    case .failed(let error): LF("无法连接：%@", error)
    case .tested(let space): SpaceSummary.subtitle(space)
    case .mounted(let mount): SpaceSummary.mounted(mount.availableBytes)
    }
  }
  // 卡片名称下的一行小字：有容量就只写容量，其余写简短状态
  static func cardCaption(_ state: ConnectionState, kind: ConnectionKind) -> String {
    if let available = availableBytes(state) { return LF("%@ 可用", ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) }
    switch state {
    case .failed: return L("出错")
    case .awaitingAuthorization: return L("等待手机授权")
    case .tested: return L("已连接")
    default: return subtitle(state, kind: kind)
    }
  }

  // 列表行的小字：有容量写容量，出错时带上原因
  static func listCaption(_ state: ConnectionState, kind: ConnectionKind, detail: String?) -> String {
    if let available = availableBytes(state) { return LF("%@ 可用", ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) }
    if case .failed = state, let detail { return LF("无法连接：%@", detail) }
    return subtitle(state, kind: kind)
  }

  private static func availableBytes(_ state: ConnectionState) -> Int64? {
    switch state {
    case .mounted(let mount): mount.availableBytes
    case .tested(let space): space.available
    default: nil
    }
  }

  static func buttonTitle(_ state: ConnectionState, kind: ConnectionKind) -> String {
    switch state {
    case .needsLogin: L("重新登录")
    case .tested: kind.usesMount ? L("挂载") : L("重新测试")
    case .mounted: L("推出")
    case .failed: L("重试")
    case .connecting, .awaitingAuthorization: L("取消")
    case .ejecting: L("正在推出…")
    case .unavailable, .disconnected: kind.usesMount ? L("挂载") : L("测试连接")
    }
  }
}
