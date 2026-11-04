import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class PanelDraggingSource: NSObject, NSDraggingSource {
  private var state = PanelDragState()
  private var changed: ((UUID?) -> Void)?
  // 拖动期间保留来源，结束回调后释放。
  private var sessionLifetime: PanelDraggingSource?

  func prepare(_ id: UUID, changed: @escaping (UUID?) -> Void) -> Bool {
    guard state.sourceID == nil else { return false }
    self.changed = changed
    state.prepare(id)
    sessionLifetime = self
    return true
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    state.didBegin()
    changed?(state.publishedSourceID)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    state.finish()
    changed?(nil)
    changed = nil
    sessionLifetime = nil
    NSCursor.arrow.set()
  }
}

struct PanelDragHandle: NSViewRepresentable {
  let id: UUID
  let source: PanelDraggingSource
  @Binding var draggedID: UUID?
  var toolTip: String? = nil
  // 没拖动就松手时弹出的菜单，右键也用它
  var menu: (() -> NSMenu)? = nil
  var clicked: () -> Void = {}

  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {
    view.identifierValue = id
    view.source = source
    view.changed = { draggedID = $0 }
    view.toolTip = toolTip
    view.menuProvider = menu
    view.clicked = clicked
  }

  final class DragView: NSView {
    var identifierValue = UUID()
    var source: PanelDraggingSource?
    var changed: ((UUID?) -> Void)?
    var menuProvider: (() -> NSMenu)?
    var clicked: (() -> Void)?
    private var initialPoint: NSPoint?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func menu(for event: NSEvent) -> NSMenu? {
      clicked?()
      return menuProvider?()
    }
    override func mouseDown(with event: NSEvent) {
      initialPoint = event.locationInWindow
      NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
      let wasClick = initialPoint != nil
      initialPoint = nil
      NSCursor.pointingHand.set()
      guard wasClick else { return }
      clicked?()
      // 菜单从卡片左下角往下弹
      if let menu = menuProvider?() { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 6 : -6), in: self) }
    }
    override func mouseDragged(with event: NSEvent) {
      guard let initialPoint,
        hypot(event.locationInWindow.x - initialPoint.x, event.locationInWindow.y - initialPoint.y) > 3,
        let host = window?.contentView, let source, let changed
      else { return }
      self.initialPoint = nil
      let item = NSDraggingItem(pasteboardWriter: identifierValue.uuidString as NSString)
      // 拖动时跟着指针的是卡片本身的截图
      let frame = convert(bounds, to: host)
      let image = NSImage(size: frame.size)
      if let rep = host.bitmapImageRepForCachingDisplay(in: frame) {
        host.cacheDisplay(in: frame, to: rep)
        image.addRepresentation(rep)
      }
      item.setDraggingFrame(frame, contents: image)
      guard source.prepare(identifierValue, changed: changed) else { return }
      let session = host.beginDraggingSession(with: [item], event: event, source: source)
      session.animatesToStartingPositionsOnCancelOrFail = true
    }
  }
}

struct PanelDropDelegate: DropDelegate {
  @Binding var source: UUID?
  @Binding var target: UUID?
  let destination: UUID?
  var onTargeted: ((Bool) -> Void)? = nil
  let move: (UUID, UUID?) -> Void
  func validateDrop(info: DropInfo) -> Bool {
    return source != nil && source != destination
  }
  func dropEntered(info: DropInfo) {
    target = destination
    onTargeted?(true)
  }
  func dropExited(info: DropInfo) {
    if target == destination { target = nil }
    onTargeted?(false)
  }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    guard let source, source != destination else { return false }
    move(source, destination)
    self.source = nil
    target = nil
    onTargeted?(false)
    return true
  }
}
