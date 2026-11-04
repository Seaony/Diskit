import Testing

@Test func discoveredLocationsUseCompactAddInsteadOfLargeEmptyState() {
  #expect(!PanelCopy.showsEmptyState(savedCount: 0, discoveredCount: 5))
}

@Test func largeEmptyStateRequiresBothSavedAndDiscoveredListsToBeEmpty() {
  #expect(PanelCopy.showsEmptyState(savedCount: 0, discoveredCount: 0))
  #expect(!PanelCopy.showsEmptyState(savedCount: 1, discoveredCount: 0))
  #expect(!PanelCopy.showsEmptyState(savedCount: 1, discoveredCount: 5))
}
