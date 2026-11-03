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
    case .aliyunDrive: "externaldrive.badge.icloud"
    case .quark: "cloud"
    }
  }
  var iconColor: Color {
    switch self {
    case .androidUSB, .androidWiFi: .green
    case .smb: .blue
    case .ricohGR: .primary
    case .aliyunDrive: .orange
    case .quark: .blue
    }
  }
  var connectionCaption: String {
    switch self {
    case .androidUSB, .androidWiFi: "USB / Wi-Fi"
    case .smb: L("局域网共享")
    case .ricohGR: L("USB 相机")
    case .aliyunDrive: L("官方授权")
    case .quark: L("实验性")
    }
  }
}
