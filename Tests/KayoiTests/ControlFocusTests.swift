import Testing

@Test func rowFocusDoesNotHighlightUnfocusedChildControls() {
  #expect(!ControlFocus.isFocused(inherited: true, explicit: false))
  #expect(ControlFocus.isFocused(inherited: false, explicit: true))
}

@Test func controlsOutsideCompositeRowsKeepTheirInheritedFocus() {
  #expect(ControlFocus.isFocused(inherited: true, explicit: nil))
  #expect(!ControlFocus.isFocused(inherited: false, explicit: nil))
}
