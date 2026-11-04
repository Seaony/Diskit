import Foundation
import Testing

private struct ContrastRGB {
  let components: [Double]
  var luminance: Double {
    zip(components, [0.2126, 0.7152, 0.0722]).reduce(0) { result, item in
      let value = item.0 <= 0.04045 ? item.0 / 12.92 : pow((item.0 + 0.055) / 1.055, 2.4)
      return result + value * item.1
    }
  }
  func over(_ other: ContrastRGB, opacity: Double) -> ContrastRGB {
    ContrastRGB(components: zip(components, other.components).map { $0 * opacity + $1 * (1 - opacity) })
  }
  func ratio(to other: ContrastRGB) -> Double {
    (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
  }
}

private func contrastVariants(_ name: String) throws -> [ContrastRGB] {
  let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "App/Assets.xcassets")
  let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "\(name).colorset/Contents.json"))) as? [String: Any])
  let colors = try #require(object["colors"] as? [[String: Any]])
  #expect(colors.count == 4)
  return try colors.map { entry in
    let color = try #require(entry["color"] as? [String: Any])
    let values = try #require(color["components"] as? [String: String])
    #expect(values["alpha"] == "1.000")
    return ContrastRGB(components: try ["red", "green", "blue"].map { key in
      let value = try #require(values[key])
      let component = try #require(UInt8(value.dropFirst(2), radix: 16))
      return Double(component) / 255
    })
  }
}

// 普通外观按 WCAG AA（正文 4.5:1），增强对比度外观（下标 2、3）按 AAA（7:1）。
// 强调色当文字只用于选中项名称和链接，普通外观按 3:1。
@Test func everyThemeTextPairMeetsContrastInAllAppearances() throws {
  var pairs: [(String, String, Double, Double)] = []
  for background in ["Background", "Surface", "Selection", "Hover", "Pressed", "ControlFill", "Field"] {
    pairs.append(("PrimaryText", background, 4.5, 7))
    pairs.append(("SecondaryText", background, 4.5, 7))
  }
  for background in ["Background", "Surface", "Hover", "ErrorBackground", "ErrorHover"] {
    pairs.append(("Error", background, 4.5, 7))
  }
  for background in ["Background", "Surface", "Hover", "WarningBackground", "WarningHover"] {
    pairs.append(("Warning", background, 4.5, 7))
  }
  pairs += [("Accent", "Background", 3, 4.5), ("Accent", "Surface", 3, 4.5), ("Accent", "Selection", 3, 4.5), ("DisabledText", "DisabledSurface", 4.5, 7)]
  for background in ["Accent", "ActionHover", "ActionPressed"] { pairs.append(("ActionText", background, 4.5, 4.5)) }
  for (foreground, background, normal, high) in pairs {
    for (index, (text, surface)) in zip(try contrastVariants(foreground), try contrastVariants(background)).enumerated() {
      #expect(text.ratio(to: surface) >= (index >= 2 ? high : normal), "\(foreground) / \(background) #\(index)")
    }
  }
}

// 普通外观下边框只做淡分隔，增强对比度（下标 2、3）才要求 3:1。
@Test func disabledButtonsAndHighContrastBordersStayVisible() throws {
  let texts = try contrastVariants("DisabledText")
  let surfaces = try contrastVariants("DisabledSurface")
  let backgrounds = try contrastVariants("Surface")
  let borders = try contrastVariants("Border")
  for index in 0..<4 {
    #expect(texts[index].over(backgrounds[index], opacity: 0.9).ratio(to: surfaces[index].over(backgrounds[index], opacity: 0.9)) >= 4.5)
    if index >= 2 { #expect(borders[index].ratio(to: backgrounds[index]) >= 3) }
  }
}
