import CoreGraphics
import Foundation

enum WindowPlacement {
  static func visibleFrame(_ frame: CGRect, screens: [CGRect], preferred: CGRect?) -> CGRect {
    guard !screens.isEmpty else { return frame }
    if screens.contains(where: { $0.contains(frame) }) { return frame }
    let intersecting = screens.max { left, right in
      area(left.intersection(frame)) < area(right.intersection(frame))
    }
    let target =
      intersecting.flatMap { area($0.intersection(frame)) > 0 ? $0 : nil }
      ?? preferred.flatMap { screens.contains($0) ? $0 : nil } ?? screens[0]
    let size = CGSize(
      width: min(frame.width, target.width), height: min(frame.height, target.height))
    return CGRect(
      x: min(max(frame.minX, target.minX), target.maxX - size.width),
      y: min(max(frame.minY, target.minY), target.maxY - size.height),
      width: size.width, height: size.height)
  }

  private static func area(_ frame: CGRect) -> CGFloat {
    frame.isNull || frame.isEmpty ? 0 : frame.width * frame.height
  }
}
