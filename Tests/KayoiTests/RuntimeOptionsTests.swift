import Testing

@Test func demoRequiresExplicitOptIn() {
  for value in ["", "0", "true", "yes"] {
    let options = RuntimeOptions(environment: [
      "KAYOI_DEMO": value, "KAYOI_PANEL_WINDOW": "1", "KAYOI_PSEUDO_LOCALE": "1",
      "KAYOI_DEMO_STATE": "failed",
    ])
    #expect(!options.isDemo)
    #expect(!options.panelWindow)
    #expect(!options.pseudoLocale)
    #expect(options.scenario == "live")
  }
}

@Test func demoOptionsSelectIsolatedScenario() {
  let options = RuntimeOptions(environment: [
    "KAYOI_DEMO": "1", "KAYOI_PANEL_WINDOW": "1", "KAYOI_PSEUDO_LOCALE": "1",
    "KAYOI_DEMO_STATE": "failed",
  ])
  #expect(options.isDemo && options.panelWindow && options.pseudoLocale)
  #expect(options.scenario == "failed")
  #expect(RuntimeOptions(environment: ["KAYOI_DEMO": "1"]).scenario == "mixed")
  #expect(RuntimeOptions(environment: [:]).scenario == "live")
}

@Test func demoAppearanceNeverChangesProduction() {
  #expect(RuntimeOptions(environment: ["KAYOI_DEMO_APPEARANCE": "dark"]).appearance == nil)
  #expect(
    RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_DEMO_APPEARANCE": "dark"]).appearance
      == "dark")
  #expect(
    RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_DEMO_APPEARANCE": "other"]).appearance
      == nil)
}
