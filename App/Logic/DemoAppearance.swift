import AppKit

@MainActor enum DemoAppearance {
  static func name(options: RuntimeOptions) -> NSAppearance.Name? {
    guard options.isDemo else { return nil }
    let dark = options.appearance.map { $0 == "dark" }
      ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    guard options.appearance != nil else { return nil }
    return dark ? .darkAqua : .aqua
  }
}
