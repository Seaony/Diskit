import SwiftUI

enum KayoiTheme {
  static let background = color(light: 0xF3F6F5, dark: 0x191F20)
  static let surface = color(light: 0xEDF2F0, dark: 0x1E2525)
  static let border = color(light: 0xDCE5E1, dark: 0x303B38)
  static let accent = color(light: 0x087A50, dark: 0x18BA80)
  static let selection = color(light: 0xD7EDE3, dark: 0x19392F)
  static let actionText = color(light: 0xFFFFFF, dark: 0x10251D)

  private static func color(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: Double((value >> 16) & 255) / 255,
          green: Double((value >> 8) & 255) / 255,
          blue: Double(value & 255) / 255, alpha: 1)
      })
  }
}
