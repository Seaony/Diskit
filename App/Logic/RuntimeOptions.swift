import Foundation

struct RuntimeOptions: Equatable, Sendable {
  static let current = RuntimeOptions(environment: ProcessInfo.processInfo.environment)
  let isDemo: Bool
  let panelWindow: Bool
  let pseudoLocale: Bool
  let appearance: String?
  let scenario: String

  init(environment: [String: String]) {
    isDemo = environment["KAYOI_DEMO"] == "1"
    panelWindow = isDemo && environment["KAYOI_PANEL_WINDOW"] == "1"
    pseudoLocale = isDemo && environment["KAYOI_PSEUDO_LOCALE"] == "1"
    let requestedAppearance = environment["KAYOI_DEMO_APPEARANCE"] ?? ""
    appearance =
      isDemo && ["light", "dark"].contains(requestedAppearance) ? requestedAppearance : nil
    scenario = isDemo ? environment["KAYOI_DEMO_STATE"] ?? "mixed" : "live"
  }
}
