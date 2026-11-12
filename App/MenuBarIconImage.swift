import AppKit

@MainActor
enum MenuBarIconImage {
  static func make(filled: Bool, dimmed: Bool, needsAttention: Bool) -> NSImage {
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
      // 绘制时取菜单栏外观的文字色，避免固化成浅色或深色。
      NSColor.labelColor.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
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
    image.isTemplate = false
    return image
  }
}
