import SwiftUI

struct FlatButtonStyle: ButtonStyle {
  var prominent = false
  // 卡片里的小按钮
  var compact = false
  var focusOverride: Bool? = nil
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let focused = ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride)
    let shape = RoundedRectangle(cornerRadius: compact ? Radius.tile : Radius.control, style: .continuous)
    return configuration.label
      .font(compact ? .subheadline.weight(.medium) : .body.weight(.medium))
      .padding(.horizontal, compact ? Space.sm : Space.md)
      .padding(.vertical, compact ? 3 : Space.xs) // grid: ok 小按钮高度 22
      .foregroundStyle(foreground(configuration))
      .background(background(configuration), in: shape)
      // 悬停和按下只在底色上叠一层浅色，不加描边
      .overlay { shape.fill(KayoiTheme.primaryText.opacity(overlayOpacity(configuration))) }
      .overlay {
        shape.strokeBorder(focused ? KayoiTheme.focus : prominent ? .clear : KayoiTheme.border, lineWidth: focused ? 2 : 0.5)
      }
      .contentShape(shape)
      .offset(y: configuration.isPressed && isEnabled && !reduceMotion ? 1 : 0) // grid: ok 按下或拖动时的短暂位移
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
  }

  private func background(_ configuration: Configuration) -> Color {
    guard isEnabled else { return KayoiTheme.disabledSurface }
    guard prominent else { return KayoiTheme.controlFill }
    return configuration.isPressed ? KayoiTheme.actionPressed : hovering ? KayoiTheme.actionHover : KayoiTheme.accent
  }

  private func overlayOpacity(_ configuration: Configuration) -> Double {
    guard isEnabled, !prominent else { return 0 }
    if configuration.isPressed { return 0.12 }
    return hovering ? 0.06 : 0
  }

  private func foreground(_ configuration: Configuration) -> Color {
    if !isEnabled { return KayoiTheme.disabledText }
    if prominent { return KayoiTheme.actionText }
    return configuration.role == .destructive ? KayoiTheme.error : KayoiTheme.primaryText
  }
}
