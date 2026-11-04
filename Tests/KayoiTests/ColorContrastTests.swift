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

@Test func everyThemeTextPairMeetsContrastInAllAppearances() throws {
  var pairs: [(String, String, Double)] = []
  for background in ["Background", "Surface", "Selection", "Hover", "Pressed"] {
    pairs.append(("PrimaryText", background, 7))
  }
  for background in ["Background", "Surface", "Selection", "Hover", "Pressed"] {
    pairs.append(("SecondaryText", background, 7))
  }
  for background in ["Background", "Surface", "Hover", "Pressed"] {
    pairs.append(("Error", background, 7))
    pairs.append(("Warning", background, 7))
  }
  pairs += [("Error", "ErrorBackground", 7), ("Error", "Surface", 7), ("Warning", "WarningBackground", 7), ("Warning", "Surface", 7), ("Accent", "Background", 7), ("Accent", "Surface", 7), ("DisabledText", "DisabledSurface", 7)]
  for background in ["Accent", "ActionHover", "ActionPressed"] { pairs.append(("ActionText", background, 4.5)) }
  for (foreground, background, minimum) in pairs {
    for (text, surface) in zip(try contrastVariants(foreground), try contrastVariants(background)) {
      #expect(text.ratio(to: surface) >= minimum, "\(foreground) / \(background)")
    }
  }
}

@Test func disabledButtonsAndHighContrastBordersStayVisible() throws {
  let texts = try contrastVariants("DisabledText")
  let surfaces = try contrastVariants("DisabledSurface")
  let backgrounds = try contrastVariants("Surface")
  let borders = try contrastVariants("Border")
  for index in 0..<4 {
    #expect(texts[index].over(backgrounds[index], opacity: 0.9).ratio(to: surfaces[index].over(backgrounds[index], opacity: 0.9)) >= 4.5)
    #expect(borders[index].ratio(to: backgrounds[index]) >= 3)
  }
}
