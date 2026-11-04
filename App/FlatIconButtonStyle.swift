import SwiftUI

struct FlatIconButtonStyle: ButtonStyle {
  var focusOverride: Bool? = nil
  @Environment(\.isFocused) private var isFocused
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body)
      .foregroundStyle(isEnabled ? KayoiTheme.secondaryText : KayoiTheme.disabledText)
      .frame(width: 30, height: 30)
      .background(configuration.isPressed ? KayoiTheme.pressed : hovering ? KayoiTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride) ? KayoiTheme.focus : .clear, lineWidth: 2) }
      .contentShape(Rectangle())
      .pointerStyle(isEnabled ? .link : nil)
      .onHover { hovering = $0 }
  }
}
