import Core
import Foundation

enum PanelCopy {

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
  static func buttonTitle(_ state: ConnectionState, kind: ConnectionKind) -> String {
    switch state {
    case .needsLogin: L("重新登录")
    case .tested: L("重新测试")
    case .mounted: L("推出")
    case .failed: L("重试")
    case .connecting, .awaitingAuthorization: L("取消")
    case .ejecting: L("正在推出…")
    case .unavailable: L("测试连接")
    case .disconnected: kind.usesSystemMount ? L("挂载") : L("测试连接")
    }
  }
}
