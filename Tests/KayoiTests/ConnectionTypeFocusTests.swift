import Core
import Testing

@Test func typeGridFocusOnlyHighlightsTheSelectedCameraAfterSearchReset() {
  let kinds = ConnectionTypeCatalog.matching("").flatMap(\.kinds)
  #expect(ConnectionTypeCatalog.matching("smb").flatMap(\.kinds) == [.smb])
  #expect(ConnectionTypeCatalog.matching("no-such-type").isEmpty)
  let afterDown = ConnectionTypeCatalog.movedSelection(kinds.first, offset: 1, query: "")
  let selected = ConnectionTypeCatalog.movedSelection(afterDown, offset: 1, query: "")
  #expect(selected == .cameraUSB)
  #expect(
    kinds.filter { ConnectionTypeFocus.isFocused($0, selection: selected, gridFocused: true) } == [
      .cameraUSB
    ])
  #expect(
    kinds.allSatisfy { !ConnectionTypeFocus.isFocused($0, selection: selected, gridFocused: false) }
  )
}

@Test func unselectedGridHasNoFocusedCard() {
  #expect(
    ConnectionKind.allCases.allSatisfy {
      !ConnectionTypeFocus.isFocused($0, selection: nil, gridFocused: true)
    })
}
