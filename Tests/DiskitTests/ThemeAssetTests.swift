import Foundation
import Testing

@Test func themeAssetsHaveOpaqueLightDarkAndHighContrastVariants() throws {
  let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "App/Assets.xcassets")
  for name in ["Background", "Surface", "Border", "ControlFill", "Field", "TertiaryText", "Accent", "Selection", "ActionText", "ErrorHover", "WarningHover", "StatusGreen", "StatusBlue", "StatusAmber", "StatusRed", "StatusGrey"] {
    let data = try Data(contentsOf: root.appending(path: "\(name).colorset/Contents.json"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let colors = try #require(object["colors"] as? [[String: Any]])
    #expect(colors.count == 4)
    var combinations = Set<String>()
    for entry in colors {
      let appearances = entry["appearances"] as? [[String: String]] ?? []
      let dark = appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" }
      let high = appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" }
      combinations.insert("\(dark)-\(high)")
      let color = try #require(entry["color"] as? [String: Any])
      #expect(color["color-space"] as? String == "srgb")
      let components = try #require(color["components"] as? [String: String])
      #expect(Double(components["alpha"] ?? "") == 1)
      for component in ["red", "green", "blue"] {
        let value = try #require(components[component])
        #expect(UInt8(value.dropFirst(2), radix: 16) != nil)
      }
    }
    #expect(combinations == ["false-false", "true-false", "false-true", "true-true"])
  }
}
