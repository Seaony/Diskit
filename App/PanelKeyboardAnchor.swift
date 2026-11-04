import AppKit
import SwiftUI

// 首开时接收键盘，不让位于发现区下方的保存行自动滚入视口。
struct PanelKeyboardAnchor: NSViewRepresentable {
  let handle: (UInt16) -> Bool
  func makeNSView(context: Context) -> KeyView { KeyView() }
  func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }

  final class KeyView: NSView {
    var handle: ((UInt16) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        window.makeFirstResponder(self)
      }
    }
    override func keyDown(with event: NSEvent) {
      let modifiers = event.modifierFlags.intersection([.command, .control, .option])
      if modifiers.isEmpty, handle?(event.keyCode) == true { return }
      super.keyDown(with: event)
    }
  }
}
