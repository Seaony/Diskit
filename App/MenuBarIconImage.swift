import AppKit

@MainActor
enum MenuBarIconImage {
  // 平时用模板图，菜单栏失焦变暗、深浅色都由系统处理，和其它菜单栏图标一致；
  // 只有要画琥珀色提醒点时才用原色图（模板图会把点也变成单色）
  static func make(filled: Bool, dimmed: Bool, needsAttention: Bool) -> NSImage {
    let template = !needsAttention
    let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      guard let glyph = NSImage(named: "DiskitBrandGlyph") else { return false }
      let glyphRect = NSRect(x: 1, y: 0, width: 16, height: 16)
      if filled {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: glyphRect, xRadius: 4.3, yRadius: 4.3).fill()
        glyph.draw(
          in: glyphRect.insetBy(dx: 2, dy: 2), from: .zero, operation: .destinationOut, fraction: 1)
      } else {
        glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
      }
      // 模板图只看透明度；原色图取菜单栏外观的文字色，避免固化成浅色或深色
      (template ? NSColor.black : NSColor.labelColor).withAlphaComponent(dimmed ? 0.45 : 1).setFill()
      rect.fill(using: .sourceIn)
      if needsAttention {
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 15, y: -1, width: 8, height: 8)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        (NSColor(named: "StatusAmber") ?? .systemOrange).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 6, height: 6)).fill()
      }
      return true
    }
    image.isTemplate = template
    return image
  }
}
