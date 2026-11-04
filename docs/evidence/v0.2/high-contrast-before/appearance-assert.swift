import AppKit
let expected = NSAppearance.Name.accessibilityHighContrastAqua
let appearance = NSAppearance(named: expected)
let actual = appearance?.bestMatch(from: [expected, .aqua])
guard actual == expected else {
  print("FAIL: 公开appearanceNamed不能在当前普通对比度环境启用高对比；actual=\(actual?.rawValue ?? "nil")")
  exit(1)
}
