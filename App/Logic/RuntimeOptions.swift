import Foundation

struct RuntimeOptions: Equatable, Sendable {
  static let current = RuntimeOptions(environment: ProcessInfo.processInfo.environment)
  let isDemo: Bool
  let panelWindow: Bool
  let pseudoLocale: Bool
  let scenario: String

  init(environment: [String: String]) {
    isDemo = environment["KAYOI_DEMO"] == "1"
    panelWindow = isDemo && environment["KAYOI_PANEL_WINDOW"] == "1"
    pseudoLocale = isDemo && environment["KAYOI_PSEUDO_LOCALE"] == "1"
    scenario = isDemo ? environment["KAYOI_DEMO_STATE"] ?? "mixed" : "live"
  }
}
