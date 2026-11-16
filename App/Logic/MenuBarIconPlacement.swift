import Foundation

enum MenuBarIconPlacement {
  // 图标中心要在屏幕内；有刘海的屏幕上，落在刘海左右两块可用区域之间的就是被挡住了
  static func isShown(_ item: CGRect, screen: CGRect, notchLeft: CGRect?, notchRight: CGRect?) -> Bool {
    guard item.width > 0, screen.contains(CGPoint(x: item.midX, y: item.midY)) else { return false }
    guard let notchLeft, let notchRight else { return true }
    return item.midX <= notchLeft.maxX || item.midX >= notchRight.minX
  }
}
