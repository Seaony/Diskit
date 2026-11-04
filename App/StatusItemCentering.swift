import AppKit
import SwiftUI

// 菜单栏面板默认左边对齐图标，这里把它挪到图标正下方居中
struct StatusItemCentering: NSViewRepresentable {
  func makeNSView(context: Context) -> CenteringView { CenteringView() }
  func updateNSView(_ view: CenteringView, context: Context) { view.center() }

  final class CenteringView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      // 打开、内容高度变化后都重新居中
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.center() }
        })
      }
      center()
    }

    func center() {
      guard let window, let screen = window.screen,
        let item = NSApp.windows.first(where: { $0.className == "NSStatusBarWindow" && $0.screen == screen })
      else { return }
      let visible = screen.visibleFrame
      var frame = window.frame
      let x = item.frame.midX - frame.width / 2
      frame.origin.x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)
      guard abs(frame.origin.x - window.frame.origin.x) > 0.5 else { return }
      window.setFrameOrigin(frame.origin)
    }
  }
}
