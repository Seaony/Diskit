import SwiftUI

struct FlatButtonStyle: ButtonStyle {
  var prominent = false
  var focusOverride: Bool? = nil
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .padding(.horizontal, Space.md)
      .padding(.vertical, Space.xs)
      .foregroundStyle(foreground(configuration))
      .background(background(configuration), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
          .strokeBorder(ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride) ? KayoiTheme.focus : KayoiTheme.border, lineWidth: ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride) ? 2 : 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .offset(y: configuration.isPressed && isEnabled && !reduceMotion ? 1 : 0) // grid: ok 按下或拖动时的短暂位移
      .opacity(isEnabled ? 1 : 0.9)
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
  }

  private func background(_ configuration: Configuration) -> Color {
    guard isEnabled else { return KayoiTheme.disabledSurface }
    if prominent {
      return configuration.isPressed ? KayoiTheme.actionPressed : hovering ? KayoiTheme.actionHover : KayoiTheme.accent
    }
    return configuration.isPressed ? KayoiTheme.pressed : hovering ? KayoiTheme.hover : KayoiTheme.surface
  }

  private func foreground(_ configuration: Configuration) -> Color {
    if !isEnabled { return KayoiTheme.disabledText }
    if prominent { return KayoiTheme.actionText }
    return configuration.role == .destructive ? KayoiTheme.error : KayoiTheme.primaryText
  }
}
