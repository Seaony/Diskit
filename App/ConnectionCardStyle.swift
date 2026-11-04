import Core
import SwiftUI

struct ConnectionCardStyle: ButtonStyle {
  let selected: Bool
  var focused = false
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed ? KayoiTheme.pressed : selected ? KayoiTheme.selection : hovering ? KayoiTheme.hover : KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
          .strokeBorder(
            focused ? KayoiTheme.focus : selected ? KayoiTheme.accent : KayoiTheme.border,
            lineWidth: selected || focused ? 2 : 1)
      }
      .overlay(alignment: .topTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(KayoiTheme.accent)
            .padding(Space.md).accessibilityHidden(true)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
      .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0) // grid: ok 按下或拖动时的短暂位移
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .onHover { hovering = $0 }
  }
}

extension ConnectionKind {
  var symbol: String {
    switch self {
    case .androidUSB, .androidWiFi: "smartphone"
    case .smb: "desktopcomputer"
    case .ricohGR: "camera"
    case .webdav, .webdavHTTPS: "externaldrive.connected.to.line.below"
    case .nfs: "network"
    case .cameraUSB: "camera.aperture"
    case .aliyunDrive, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox,
      .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak:
      "cloud"
    case .quark, .ucDrive: "cloud.fill"
    case .lanzou: "shippingbox"
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      "externaldrive.badge.icloud"
    }
  }
  var iconColor: Color {
    let name: String
    switch self {
    case .androidUSB, .androidWiFi: name = "green"
    case .smb: name = "blue"
    case .ricohGR, .cameraUSB: name = "gray"
    case .webdav, .webdavHTTPS, .nfs: name = "teal"
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2, .aliyunDrive: name = "orange"
    case .quark, .ucDrive: name = "blue"
    default: name = "purple"
    }
    return KayoiTheme.locationColor(name)
  }
  var connectionCaption: String {
    switch self {
    case .androidUSB, .androidWiFi: L("USB / Wi-Fi")
    case .smb: L("局域网共享")
    case .ricohGR: L("USB 相机")
    case .cameraUSB: L("相机的 USB 连接")
    case .webdav: L("HTTP WebDAV")
    case .webdavHTTPS: L("加密 WebDAV")
    case .nfs: L("网络文件系统")
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      L("对象存储")
    case .aliyunDrive: L("官方授权")
    case .quark, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      L("实验性")
    case .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox:
      L("官方授权")
    }
  }
  var sortOrder: Int {
    switch self {
    case .androidUSB, .androidWiFi: 0
    case .smb, .webdav, .webdavHTTPS, .nfs: 1
    case .ricohGR, .cameraUSB: 2
    case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
      .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      3
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2: 4
    }
  }
  var accentColor: Color { iconColor }
  var isCloud: Bool {
    switch self {
    case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
      .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      true
    default: false
    }
  }
}
