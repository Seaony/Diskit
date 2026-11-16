import Foundation
import Testing

// 数值取自 14 寸 MacBook 内置屏和一块外接屏的实测坐标
@Test func menuBarIconHiddenUnderNotchOrOffScreenFallsBackToWindow() {
  let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
  let left = CGRect(x: 0, y: 950, width: 663.5, height: 32)
  let right = CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
  let external = CGRect(x: -210, y: 982, width: 1920, height: 1080)
  func icon(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 38, height: 33) }

  #expect(MenuBarIconPlacement.isShown(icon(1007, 949), screen: builtIn, notchLeft: left, notchRight: right))
  #expect(MenuBarIconPlacement.isShown(icon(600, 949), screen: builtIn, notchLeft: left, notchRight: right))
  #expect(!MenuBarIconPlacement.isShown(icon(740, 949), screen: builtIn, notchLeft: left, notchRight: right))
  #expect(!MenuBarIconPlacement.isShown(icon(0, -33), screen: builtIn, notchLeft: left, notchRight: right))
  #expect(MenuBarIconPlacement.isShown(icon(1205, 2030), screen: external, notchLeft: nil, notchRight: nil))
  #expect(!MenuBarIconPlacement.isShown(.zero, screen: external, notchLeft: nil, notchRight: nil))
}
