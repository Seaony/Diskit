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

// 打开面板时没有选中；第一次按方向键选中第一个，而不是跳到第二个
@Test func firstArrowKeySelectsTheFirstLocation() {
  let ids = [UUID(), UUID(), UUID(), UUID()]
  var selection = PanelSelection()
  #expect(selection.id == nil)
  selection.move(3, in: ids)
  #expect(selection.id == ids[0])
  #expect(selection.scrollRequest?.connectionID == ids[0])
  selection.move(1, in: ids)
  #expect(selection.id == ids[1])
  selection.move(3, in: ids)
  #expect(selection.id == ids[1])
  selection.move(-1, in: ids)
  selection.move(-1, in: ids)
  #expect(selection.id == ids[0])
  var empty = PanelSelection()
  empty.move(1, in: [])
  #expect(empty.id == nil)
}

@Test func deletedSelectionLeavesNothingSelected() {
  let ids = [UUID(), UUID()]
  var selection = PanelSelection()
  selection.select(ids[1], reveal: false)
  selection.keep(in: ids)
  #expect(selection.id == ids[1])
  selection.keep(in: [ids[0]])
  #expect(selection.id == nil)
}
