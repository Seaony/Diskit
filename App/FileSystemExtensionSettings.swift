import SwiftUI

struct FileSystemExtensionSettings: View {
  let state: FileSystemExtensionState
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      KayoiSideRow(L("文件系统扩展")) {
        HStack(spacing: Space.sm) {
          if state == .checking {
            ProgressView().nativeProgressAppearance().controlSize(.mini)
              .accessibilityHidden(true)
          }
          Text(status)
            .foregroundStyle(state == .disabled ? KayoiTheme.warning : KayoiTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
      }
      Button(L("打开系统设置"), action: openSettings)
        .buttonStyle(FlatButtonStyle())
        .overlay {
          // 和现有 FlatButtonStyle 的轮廓保持一致。
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(KayoiTheme.border, lineWidth: 0.5)
            .allowsHitTesting(false)
        }
    }
    .accessibilityElement(children: .contain)
  }

  private var status: String {
    switch state {
    case .checking: L("正在检查…")
    case .enabled: L("已启用")
    case .disabled: L("未启用")
    case .unavailable: L("当前构建不可用")
    }
  }
}

#Preview("扩展状态 · 浅色") {
  KayoiFormSection {
    FileSystemExtensionSettings(state: .checking, openSettings: {})
    FileSystemExtensionSettings(state: .enabled, openSettings: {})
    FileSystemExtensionSettings(state: .disabled, openSettings: {})
    FileSystemExtensionSettings(state: .unavailable, openSettings: {})
  }
  .padding(Space.margin).frame(width: 560)
  .background(KayoiTheme.background).preferredColorScheme(.light)
}

#Preview("扩展状态 · 深色") {
  KayoiFormSection {
    FileSystemExtensionSettings(state: .checking, openSettings: {})
    FileSystemExtensionSettings(state: .enabled, openSettings: {})
    FileSystemExtensionSettings(state: .disabled, openSettings: {})
    FileSystemExtensionSettings(state: .unavailable, openSettings: {})
  }
  .padding(Space.margin).frame(width: 560)
  .background(KayoiTheme.background).preferredColorScheme(.dark)
}
