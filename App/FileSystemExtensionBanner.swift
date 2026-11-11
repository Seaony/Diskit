import SwiftUI

struct FileSystemExtensionBanner: View {
  let state: FileSystemExtensionState
  let openSettings: () -> Void

  var body: some View {
    if state == .disabled {
      Button(action: openSettings) {
        HStack(alignment: .top, spacing: Space.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .frame(width: Space.lg)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(L("启用文件系统扩展"))
              .font(.subheadline.weight(.semibold))
            Text(L("在系统设置中启用 Kayoi 后即可挂载位置。"))
              .font(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .padding(.top, Space.xs)
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(FileSystemExtensionBannerStyle())
      .accessibilityLabel(L("启用文件系统扩展"))
      .accessibilityHint(L("在系统设置中启用 Kayoi 后即可挂载位置。"))
      .help(L("打开系统设置"))
    }
  }
}

private struct FileSystemExtensionBannerStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
    return configuration.label
      .padding(Space.md)
      .foregroundStyle(isEnabled ? KayoiTheme.warning : KayoiTheme.disabledText)
      .background(background, in: shape)
      .overlay {
        shape.fill(KayoiTheme.warning.opacity(configuration.isPressed && isEnabled ? 0.08 : 0))
      }
      .overlay {
        shape.strokeBorder(
          isFocused ? KayoiTheme.focus : KayoiTheme.border,
          lineWidth: isFocused ? 2 : 0.5)
      }
      .contentShape(shape)
      .pointerStyle(isEnabled ? .link : nil)
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
  }

  private var background: Color {
    if !isEnabled { return KayoiTheme.disabledSurface }
    return hovering ? KayoiTheme.warningHover : KayoiTheme.warningBackground
  }
}

#Preview("扩展未启用 · 浅色") {
  FileSystemExtensionBanner(state: .disabled, openSettings: {})
    .padding(Space.lg).frame(width: 380)
    .background(KayoiTheme.background).preferredColorScheme(.light)
}

#Preview("扩展未启用 · 深色") {
  FileSystemExtensionBanner(state: .disabled, openSettings: {})
    .padding(Space.lg).frame(width: 380)
    .background(KayoiTheme.background).preferredColorScheme(.dark)
}
