import SwiftUI

struct FlatButtonStyle: ButtonStyle {
  var prominent = false
  var focusOverride: Bool? = nil
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let focused = ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride)
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    return configuration.label
      .font(.system(size: 13, weight: .medium))
      .padding(.horizontal, 14) // grid: ok 设计稿按钮左右 14
      .frame(minHeight: 28)
      .foregroundStyle(foreground(configuration))
      .background(background(configuration), in: shape)
      // 悬停和按下只在底色上叠一层浅色，不加描边
      .overlay { shape.fill(DiskitTheme.primaryText.opacity(overlayOpacity(configuration))) }
      .overlay {
        shape.strokeBorder(focused ? DiskitTheme.focus : .clear, lineWidth: 2)
      }
      .contentShape(shape)
      .pointerStyle(isEnabled ? .link : nil)
      .offset(y: configuration.isPressed && isEnabled && !reduceMotion ? 1 : 0) // grid: ok 按下或拖动时的短暂位移
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
  }

  private func background(_ configuration: Configuration) -> Color {
    guard isEnabled else { return DiskitTheme.disabledSurface }
    guard prominent else { return DiskitTheme.controlFill }
    return configuration.isPressed ? DiskitTheme.actionPressed : hovering ? DiskitTheme.actionHover : DiskitTheme.accent
  }

  private func overlayOpacity(_ configuration: Configuration) -> Double {
    guard isEnabled, !prominent else { return 0 }
    if configuration.isPressed { return 0.12 }
    return hovering ? 0.06 : 0
  }

  private func foreground(_ configuration: Configuration) -> Color {
    if !isEnabled { return DiskitTheme.disabledText }
    if prominent { return DiskitTheme.actionText }
    return configuration.role == .destructive ? DiskitTheme.error : DiskitTheme.primaryText
  }
}
