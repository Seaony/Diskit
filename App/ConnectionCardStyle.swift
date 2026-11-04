import Core
import SwiftUI

struct ConnectionCardStyle: ButtonStyle {
  let selected: Bool
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        selected ? KayoiTheme.selection : KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            selected
              ? KayoiTheme.accent
              : hovering ? Color.primary.opacity(0.3) : KayoiTheme.border,
            lineWidth: selected ? 2 : 1)
      }
      .overlay(alignment: .topTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(KayoiTheme.accent)
            .padding(10).accessibilityHidden(true)
        }
      }
      .overlay {
        if configuration.isPressed {
          RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.08))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 12))
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
    switch self {
    case .androidUSB, .androidWiFi: .green
    case .smb: .blue
    case .ricohGR, .cameraUSB: .primary
    case .aliyunDrive: .orange
    case .quark, .ucDrive: .blue
    case .webdav, .webdavHTTPS, .nfs: .teal
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2: .orange
    case .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox, .tianyiDrive,
      .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      .purple
    }
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
