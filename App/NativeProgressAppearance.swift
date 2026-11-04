import SwiftUI

private struct NativeProgressAppearance: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .progressViewStyle(.circular)
      .tint(KayoiTheme.primaryText)
      // 外观切换后重建系统控件，避免保留上一外观的进度圈。
      .id("native-progress-\(colorScheme == .dark)-\(contrast == .increased)")
  }
}

private struct NativeLinearProgressAppearance: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .progressViewStyle(.linear)
      .tint(KayoiTheme.accent)
      .id("native-linear-progress-\(colorScheme == .dark)-\(contrast == .increased)")
  }
}

extension View {
  func nativeProgressAppearance() -> some View { modifier(NativeProgressAppearance()) }
  func nativeLinearProgressAppearance() -> some View { modifier(NativeLinearProgressAppearance()) }
}

#Preview("原生进度圈 · 浅色") {
  HStack {
    ProgressView().nativeProgressAppearance().controlSize(.mini)
    ProgressView().nativeProgressAppearance().controlSize(.small)
  }
  .padding().background(KayoiTheme.surface).preferredColorScheme(.light)
}

#Preview("原生进度圈 · 深色") {
  HStack {
    ProgressView().nativeProgressAppearance().controlSize(.mini)
    ProgressView().nativeProgressAppearance().controlSize(.small)
  }
  .padding().background(KayoiTheme.surface).preferredColorScheme(.dark)
}

#Preview("原生线性进度 · 浅色") {
  ProgressView(value: 0.36).nativeLinearProgressAppearance()
    .frame(width: 320).padding().background(KayoiTheme.surface).preferredColorScheme(.light)
}

#Preview("原生线性进度 · 深色") {
  ProgressView(value: 0.36).nativeLinearProgressAppearance()
    .frame(width: 320).padding().background(KayoiTheme.surface).preferredColorScheme(.dark)
}
