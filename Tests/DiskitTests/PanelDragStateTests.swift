import Foundation
import Testing

@Test func dragSourceIsNotPublishedBeforeNativeSessionBegins() {
  var state = PanelDragState()
  let id = UUID()
  state.prepare(id)
  #expect(state.publishedSourceID == nil)
  state.didBegin()
  #expect(state.publishedSourceID == id)
}

@Test func dragTerminationClearsSourceOnDropCancelOrViewRemoval() {
  for didBegin in [false, true] {
    var state = PanelDragState()
    state.prepare(UUID())
    if didBegin { state.didBegin() }
    state.finish()
    #expect(state.sourceID == nil)
    #expect(state.publishedSourceID == nil)
    #expect(!state.isDragging)
    state.finish()
    #expect(state.publishedSourceID == nil)
  }
}
