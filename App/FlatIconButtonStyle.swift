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
      .frame(width: 28, height: 28)
      .background(configuration.isPressed ? KayoiTheme.pressed : hovering ? KayoiTheme.hover : KayoiTheme.background, in: Circle())
      .overlay { Circle().strokeBorder(ControlFocus.isFocused(inherited: isFocused, explicit: focusOverride) ? KayoiTheme.focus : .clear, lineWidth: 2) }
      .contentShape(Circle())
      .onHover { hovering = $0 }
  }
}
