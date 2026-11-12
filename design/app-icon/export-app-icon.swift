// 用当前图标原图导出 macOS AppIcon 全部尺寸、README 图标和面板左上角的 BrandLogo。
// AppIcon 规格：1024 画布，824 圆角方形居中，圆角 184，下方投影；原图铺满圆角方形。
// 用法：swift design/app-icon/export-app-icon.swift（在仓库根目录运行）
import AppKit

let source = NSImage(contentsOfFile: "design/app-icon/folder-peek.png")!

func bitmap(_ size: Int, _ draw: (CGContext) -> Void) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw(NSGraphicsContext.current!.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ size: Int) -> Data {
  bitmap(size) { context in
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 184, cornerHeight: 184, transform: nil)
    // 投影参数按实际像素计算，不随画布缩放，所以手动乘上比例
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: NSColor(white: 0, alpha: 0.28).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()
    context.addPath(shape)
    context.clip()
    source.draw(in: plate)
  }
}

// 面板 Logo 在代码里切圆角，这里只出铺满的正方形
func logo(_ size: Int) -> Data {
  bitmap(size) { context in
    source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
  }
}

let set = "App/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
  try! appIcon(size).write(to: URL(filePath: "\(set)/icon-\(size).png"))
}
try! appIcon(512).write(to: URL(filePath: "docs/assets/icon-512.png"))
try! logo(64).write(to: URL(filePath: "App/Assets.xcassets/BrandLogo.imageset/logo.png"))
try! logo(128).write(to: URL(filePath: "App/Assets.xcassets/BrandLogo.imageset/logo@2x.png"))
print("已导出 AppIcon、docs/assets/icon-512.png 和 BrandLogo")
