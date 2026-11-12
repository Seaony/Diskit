import AppKit
import Testing
import UserNotifications

@Test func productionIgnoresAllPresentationDemoFlags() {
  let options = RuntimeOptions(environment: [
    "DISKIT_DEMO_NOTIFICATION": "denied", "DISKIT_DEMO_LOGIN_ITEM": "error",
    "DISKIT_DEMO_DISCOVERY_ERROR": "permission", "DISKIT_DEMO_LOAD_ERROR": "1",
  ])
  #expect(options.demoNotification == nil)
  #expect(options.demoLoginItem == nil)
  #expect(options.demoDiscoveryError == nil)
  #expect(!options.demoLoadError)
}

@Test func demoPresentationFlagsRejectUnknownValues() {
  let options = RuntimeOptions(environment: [
    "DISKIT_DEMO": "1", "DISKIT_DEMO_NOTIFICATION": "invalid",
    "DISKIT_DEMO_LOGIN_ITEM": "invalid", "DISKIT_DEMO_DISCOVERY_ERROR": "invalid",
    "DISKIT_DEMO_LOAD_ERROR": "true",
  ])
  #expect(options.demoNotification == nil)
  #expect(options.demoLoginItem == nil)
  #expect(options.demoDiscoveryError == nil)
  #expect(!options.demoLoadError)
}

@Test func discoveryFixturesPreserveRealBannerActions() {
  #expect(DemoDiscoveryError.permission.permissionDenied)
  for error in DemoDiscoveryError.allCases {
    #expect(!error.message.isEmpty)
    #expect(error.permissionDenied == (error == .permission))
    let options = RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_DISCOVERY_ERROR": error.rawValue])
    #expect(options.demoDiscoveryError == error)
  }
  #expect(DemoLoginItemState.error.errorMessage != nil)
  #expect(!DemoLoginItemState.error.isEnabled)
  #expect(DemoLoginItemState.requiresApproval.isEnabled)
}

@MainActor @Test func demoNotificationsStartAtSelectedStateWithoutSystemAuthorization() async {
  for state in DemoNotificationState.allCases {
    let model = AppModel(options: RuntimeOptions(environment: [
      "DISKIT_DEMO": "1", "DISKIT_DEMO_NOTIFICATION": state.rawValue,
    ]))
    #expect(model.notificationAuthorization == state.authorization)
    await model.refreshNotificationAuthorization()
    #expect(model.notificationAuthorization == state.authorization)
  }
}
