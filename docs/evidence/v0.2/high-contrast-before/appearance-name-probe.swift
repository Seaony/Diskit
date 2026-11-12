import AppKit
let bundle = Bundle(path: "/Users/seaony/code/Diskit/build/DerivedData/Build/Products/Debug/Diskit.app")!
for name in [NSAppearance.Name.aqua, .accessibilityHighContrastAqua, .darkAqua, .accessibilityHighContrastDarkAqua] {
  let appearance = NSAppearance(named: name)!
  var color = "unavailable"
  appearance.performAsCurrentDrawingAppearance {
    if let resolved = NSColor(named: "Border", bundle: bundle)?.usingColorSpace(.deviceRGB) {
      color = "\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent)"
    }
  }
  let matched = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
  print("requested=\(name.rawValue) actual=\(appearance.name.rawValue) best=\(matched?.rawValue ?? "nil") borderRGB=\(color)")
}
