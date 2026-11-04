import Core
import Foundation
import UserNotifications

enum DemoNotificationState: String, CaseIterable, Sendable {
  case notDetermined, authorized, denied
  var authorization: UNAuthorizationStatus {
    switch self {
    case .notDetermined: .notDetermined
    case .authorized: .authorized
    case .denied: .denied
    }
  }
}

enum DemoLoginItemState: String, CaseIterable, Sendable {
  case disabled, enabled, requiresApproval, error
  var isEnabled: Bool { self == .enabled || self == .requiresApproval }
  var errorMessage: String? {
    self == .error ? L("无法注册开机启动，请在系统设置中检查登录项权限。") : nil
  }
}

enum DemoDiscoveryError: String, CaseIterable, Sendable {
  case permission, network, usb, ricoh, camera
  var permissionDenied: Bool { self == .permission }
  var message: String {
    switch self {
    case .permission: L("请允许 Kayoi 访问本地网络")
    case .network: L("暂时无法发现局域网设备，请检查网络连接")
    case .usb: L("暂时无法发现 USB 手机，请重新插拔设备")
    case .ricoh: L("暂时无法发现理光相机，请检查 USB 连接")
    case .camera: L("暂时无法发现相机，请检查 USB 连接")
    }
  }
}
