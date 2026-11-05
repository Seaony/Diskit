import AppKit

// 设置里的外观：跟随系统、浅色、深色，切换后立即生效
enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark
  static let storageKey = "appearance"
  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: L("跟随系统")
    case .light: L("浅色")
    case .dark: L("深色")
    }
  }

  var symbol: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }

  @MainActor func apply() {
    NSApplication.shared.appearance =
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
  }
}
