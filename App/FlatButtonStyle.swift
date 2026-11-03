import SwiftUI

struct FlatButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .foregroundStyle(foreground(configuration))
      .background(
        prominent && isEnabled ? KayoiTheme.accent : KayoiTheme.surface,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(KayoiTheme.border, lineWidth: 1)
      }
      .overlay {
        if configuration.isPressed && isEnabled {
          RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.12))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  private func foreground(_ configuration: Configuration) -> Color {
    if !isEnabled { return Color(nsColor: .disabledControlTextColor) }
    if prominent { return KayoiTheme.actionText }
    if configuration.role == .destructive { return .red }
    return .primary
  }
}
