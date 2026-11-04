import SwiftUI

enum KayoiTheme {
  static let background = Color("Background")
  static let surface = Color("Surface")
  static let border = Color("Border")
  static let controlFill = Color("ControlFill")
  static let field = Color("Field")
  static let segmentSelected = Color("SegmentSelected")
  static let tertiaryText = Color("TertiaryText")
  static let errorHover = Color("ErrorHover")
  static let warningHover = Color("WarningHover")
  // 状态点颜色，只用于角标和提醒，不当文字
  static let statusGreen = Color("StatusGreen")
  static let statusBlue = Color("StatusBlue")
  static let statusAmber = Color("StatusAmber")
  static let statusRed = Color("StatusRed")
  static let statusGrey = Color("StatusGrey")
  static let accent = Color("Accent")
  static let selection = Color("Selection")
  static let actionText = Color("ActionText")
  static let primaryText = Color("PrimaryText")
  static let secondaryText = Color("SecondaryText")
  static let disabledText = Color("DisabledText")
  static let disabledSurface = Color("DisabledSurface")
  static let hover = Color("Hover")
  static let pressed = Color("Pressed")
  static let actionHover = Color("ActionHover")
  static let actionPressed = Color("ActionPressed")
  static let error = Color("Error")
  static let errorBackground = Color("ErrorBackground")
  static let warning = Color("Warning")
  static let warningBackground = Color("WarningBackground")
  static let focus = Color("Focus")

  static let locationColorNames = ["blue", "green", "orange", "red", "purple", "pink", "teal", "gray"]

  static func locationColor(_ name: String) -> Color {
    let normalized = locationColorNames.contains(name) ? name : "blue"
    return Color("Location" + normalized.prefix(1).uppercased() + normalized.dropFirst())
  }
}
