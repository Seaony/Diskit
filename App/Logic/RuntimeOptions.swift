import Core
import Foundation

struct RuntimeOptions: Equatable, Sendable {
  static let current = RuntimeOptions(environment: ProcessInfo.processInfo.environment)
  let performanceOutput: String?
  let isDemo: Bool
  let panelWindow: Bool
  let pseudoLocale: Bool
  let appearance: String?
  let scenario: String
  let demoEditorKind: ConnectionKind?
  let demoEditorState: DemoEditorState?
  let demoWebService: WebLoginService?
  let layoutDirectory: String?
  // 演示模式下把面板离屏渲染成 PNG 写到这个绝对路径后退出，用于生成 README 产品图
  let productShotPath: String?
  let showsLayoutGrid: Bool
  let demoSettingsTab: String?
  let demoNotification: DemoNotificationState?
  let demoLoginItem: DemoLoginItemState?
  let demoDiscoveryError: DemoDiscoveryError?
  let demoLoadError: Bool

  init(environment: [String: String]) {
    isDemo = environment["DISKIT_DEMO"] == "1"
    performanceOutput = isDemo ? environment["DISKIT_PERF_OUTPUT"].flatMap {
      $0.hasPrefix("/") ? $0 : nil
    } : nil
    demoNotification = isDemo ? DemoNotificationState(rawValue: environment["DISKIT_DEMO_NOTIFICATION"] ?? "") : nil
    demoLoginItem = isDemo ? DemoLoginItemState(rawValue: environment["DISKIT_DEMO_LOGIN_ITEM"] ?? "") : nil
    demoDiscoveryError = isDemo ? DemoDiscoveryError(rawValue: environment["DISKIT_DEMO_DISCOVERY_ERROR"] ?? "") : nil
    demoLoadError = isDemo && environment["DISKIT_DEMO_LOAD_ERROR"] == "1"
    layoutDirectory = isDemo ? environment["DISKIT_LAYOUT_DIR"].flatMap { $0.isEmpty ? nil : $0 } : nil
    productShotPath = isDemo ? environment["DISKIT_PRODUCT_SHOT"].flatMap { $0.hasPrefix("/") ? $0 : nil } : nil
    showsLayoutGrid = isDemo && environment["APP_GRID"] == "1"
    demoSettingsTab = isDemo ? environment["DISKIT_DEMO_SETTINGS_TAB"] : nil
    panelWindow = isDemo && environment["DISKIT_PANEL_WINDOW"] == "1"
    pseudoLocale = isDemo && environment["DISKIT_PSEUDO_LOCALE"] == "1"
    let requestedAppearance = environment["DISKIT_DEMO_APPEARANCE"] ?? ""
    appearance =
      isDemo && ["light", "dark"].contains(requestedAppearance) ? requestedAppearance : nil
    scenario = isDemo ? environment["DISKIT_DEMO_STATE"] ?? "mixed" : "live"
    demoEditorKind =
      isDemo ? ConnectionKind(rawValue: environment["DISKIT_DEMO_EDITOR_TYPE"] ?? "") : nil
    demoEditorState =
      demoEditorKind == nil
      ? nil : DemoEditorState(rawValue: environment["DISKIT_DEMO_EDITOR_STATE"] ?? "blank") ?? .blank
    demoWebService =
      isDemo ? WebLoginService(rawValue: environment["DISKIT_DEMO_WEB_SERVICE"] ?? "") : nil
  }
}

enum DemoEditorState: String, CaseIterable, Sendable { case blank, filled, error, testing, success }
