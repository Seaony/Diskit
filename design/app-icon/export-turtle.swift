// 用小花怪兽原图导出 macOS AppIcon 全部尺寸和 README 图标。
// 规格沿用原图标：1024 画布，824 圆角方形居中，圆角 184，下方投影。
// 用法：swift design/app-icon/export-turtle.swift（在仓库根目录运行）
import AppKit

let source = NSImage(contentsOfFile: "design/app-icon/coral-crown-turtle.png")!
let background = NSColor(srgbRed: 0xFB / 255, green: 0x7C / 255, blue: 0x67 / 255, alpha: 1)

func render(_ size: Int) -> Data {
  let scale = CGFloat(size) / 1024
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: scale, y: scale)
  let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
  let shape = CGPath(roundedRect: plate, cornerWidth: 184, cornerHeight: 184, transform: nil)
  // 投影；阴影参数按实际像素计算，不随画布缩放，所以要手动乘上比例
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: NSColor(srgbRed: 0.55, green: 0.2, blue: 0.15, alpha: 0.25).cgColor)
  context.addPath(shape)
  context.setFillColor(background.cgColor)
  context.fillPath()
  context.restoreGState()
  // 原图缩小到 88%，四周留出珊瑚色边；小怪兽偏左，往右挪一点让它看起来居中
  context.addPath(shape)
  context.clip()
  let side: CGFloat = 824 * 0.88
  let art = CGRect(x: plate.midX - side / 2 + 30, y: plate.midY - side / 2, width: side, height: side)
  source.draw(in: art)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let set = "App/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
  try! render(size).write(to: URL(filePath: "\(set)/icon-\(size).png"))
}
try! render(512).write(to: URL(filePath: "docs/assets/icon-512.png"))
print("已导出 AppIcon 和 docs/assets/icon-512.png")
