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

@Test func layoutDiagnosticsRequireDemoMode() {
  let environment = ["KAYOI_LAYOUT_DIR": "/tmp/layout", "APP_GRID": "1", "KAYOI_DEMO_SETTINGS_TAB": "about"]
  let live = RuntimeOptions(environment: environment)
  #expect(live.layoutDirectory == nil)
  #expect(!live.showsLayoutGrid)
  #expect(live.demoSettingsTab == nil)
  let demo = RuntimeOptions(environment: environment.merging(["KAYOI_DEMO": "1"]) { _, new in new })
  #expect(demo.layoutDirectory == "/tmp/layout")
  #expect(demo.showsLayoutGrid)
  #expect(demo.demoSettingsTab == "about")
}

@Test func productShotOnlyRunsInDemoWithAbsolutePath() {
  #expect(RuntimeOptions(environment: ["KAYOI_PRODUCT_SHOT": "/tmp/panel.png"]).productShotPath == nil)
  #expect(RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_PRODUCT_SHOT": "panel.png"]).productShotPath == nil)
  #expect(
    RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_PRODUCT_SHOT": "/tmp/panel.png"]).productShotPath
      == "/tmp/panel.png")
}
