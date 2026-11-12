import AppKit
import SwiftUI

// 演示模式下把真实面板放进屏幕外的窗口，等入场动画结束后按 2 倍分辨率截成 PNG，写完退出
@MainActor enum DemoProductShot {
  static func write(model: AppModel, to path: String) async {
    let view = PanelView(model: model)
      .defaultAppStorage(model.preferences)
      .background(DiskitTheme.background)
      .tint(DiskitTheme.accent)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 380, height: 560),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSApplication.shared.appearance
    window.contentView = hosting
    window.orderFront(nil)
    try? await Task.sleep(for: .milliseconds(1200))
    window.setContentSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(1500))
    let size = hosting.bounds.size
    // 自建 2 倍位图，不受屏幕外窗口的缩放影响
    if let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    {
      rep.size = size
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      do {
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: URL(filePath: path))
      } catch {
        FileHandle.standardError.write(Data("产品图写入失败：\(error.localizedDescription)\n".utf8))
        exit(1)
      }
    } else {
      exit(1)
    }
    window.orderOut(nil)
    // 演示进程的数据都在临时目录，不需要走正常退出流程
    exit(0)
  }
}
