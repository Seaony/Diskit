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
  let name: String
  let source: PanelDraggingSource
  @Binding var draggedID: UUID?

  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {
    view.identifierValue = id
    view.title = name
    view.source = source
    view.changed = { draggedID = $0 }
  }

  final class DragView: NSView {
    var identifierValue = UUID()
    var title = ""
    var source: PanelDraggingSource?
    var changed: ((UUID?) -> Void)?
    private var initialPoint: NSPoint?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
      initialPoint = event.locationInWindow
      NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
      initialPoint = nil
      NSCursor.openHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
      guard let initialPoint,
        hypot(event.locationInWindow.x - initialPoint.x, event.locationInWindow.y - initialPoint.y) > 3,
        let host = window?.contentView, let source, let changed
      else { return }
      self.initialPoint = nil
      let item = NSDraggingItem(pasteboardWriter: identifierValue.uuidString as NSString)
      let title = self.title
      let label = NSImage(size: NSSize(width: 240, height: 44), flipped: false) { rect in
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        (title as NSString).draw(in: rect.insetBy(dx: 12, dy: 12), withAttributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor])
        return true
      }
      let origin = host.convert(NSPoint.zero, from: self)
      item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 240, height: 44)), contents: label)
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
