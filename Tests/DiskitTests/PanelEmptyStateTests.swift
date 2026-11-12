import Testing

@Test func emptyStateShowsOnlyWhenNoSavedLocations() {
  #expect(PanelCopy.showsEmptyState(savedCount: 0, hasLoadError: false))
  #expect(!PanelCopy.showsEmptyState(savedCount: 1, hasLoadError: false))
}

@Test func loadErrorReplacesEmptyState() {
  #expect(!PanelCopy.showsEmptyState(savedCount: 0, hasLoadError: true))
}
