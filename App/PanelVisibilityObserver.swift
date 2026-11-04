import AppKit
import SwiftUI

struct PanelVisibilityObserver: NSViewRepresentable {
  @Binding var visible: Bool
  func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
  func updateNSView(_ view: VisibilityView, context: Context) { view.changed = { visible = $0 } }

  final class VisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      if let window {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
          NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
        }
      }
      updateVisibility()
    }
    @objc private func updateVisibility() {
      let isVisible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
      DispatchQueue.main.async { [weak self] in self?.changed?(isVisible) }
    }
  }
}
