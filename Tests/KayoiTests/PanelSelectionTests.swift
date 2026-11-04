import Foundation
import Testing

@Test func initialPanelSelectionDoesNotRequestScrolling() {
  var selection = PanelSelection()
  let first = UUID()
  selection.select(first, reveal: false)
  #expect(selection.id == first)
  #expect(selection.scrollRequest == nil)
}

@Test func explicitPanelNavigationRevealsEvenTheAlreadySelectedRow() throws {
  var selection = PanelSelection()
  let first = UUID()
  selection.select(first, reveal: false)
  selection.select(first, reveal: true)
  let firstRequest = try #require(selection.scrollRequest)
  #expect(firstRequest.connectionID == first)
  selection.select(first, reveal: true)
  #expect(selection.scrollRequest?.connectionID == first)
  #expect(selection.scrollRequest?.id != firstRequest.id)
}
