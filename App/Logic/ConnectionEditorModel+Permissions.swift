import ADB
import AppKit
import CameraUSB
import Core
import RicohGR

extension ConnectionEditorModel {
  var permissionSettingsURL: URL? {
    guard !model.options.isDemo else { return nil }
    switch draft.kind {
    case .cameraUSB:
      if case .permissionDenied? = model.cameraUSBDiscovery.issue {
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
      }
    case .ricohGR:
      if case .permissionDenied? = model.ricohDiscovery.issue {
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
      }
    case .androidWiFi:
      if case .permissionDenied? = model.wirelessDiscovery.issue {
        return URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
      }
    case .smb:
      if case .permissionDenied? = model.discovery.issue {
        return URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
      }
    default: break
    }
    return nil
  }
  var visibleError: String? {
    error ?? (permissionSettingsURL == nil ? nil : L("系统权限尚未开启，请在系统设置中允许 Diskit 访问。"))
  }
  func openPermissionSettings() {
    guard let url = permissionSettingsURL else { return }
    NSWorkspace.shared.open(url)
  }
}
