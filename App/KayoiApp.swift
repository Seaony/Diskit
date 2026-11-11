import Core
import SwiftUI
import UserNotifications

@MainActor
final class KayoiAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  weak var model: AppModel?
  let windows = WindowCoordinator()
  let performance = DemoPerformanceProbe(options: .current)
  private var openPanel: (() -> Void)?
  private var pendingReopen = false

  func configure(model: AppModel, openPanel: @escaping () -> Void) {
    self.model = model
    self.openPanel = openPanel
    // 发现设备的通知带“添加”“不用了”按钮；演示模式不碰系统通知
    if !model.options.isDemo {
      UNUserNotificationCenter.current().delegate = self
      AppModel.registerDevicePromptCategory()
    }
    windows.start()
    if pendingReopen { reopenPanel() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !windows.showExistingWindow() { reopenPanel() }
    return false
  }

  func applicationWillTerminate(_ notification: Notification) { windows.stop() }

  // 点了通知上的按钮：添加或不再询问；点通知本身打开面板
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    let key = response.notification.request.content.userInfo[DevicePrompt.keyInfo] as? String
    await MainActor.run {
      guard let key, action != UNNotificationDefaultActionIdentifier else {
        reopenPanel()
        return
      }
      switch action {
      case DevicePrompt.mountAction: model?.respondToDevicePrompt(key: key, accept: true)
      case DevicePrompt.declineAction: model?.respondToDevicePrompt(key: key, accept: false)
      default: break
      }
    }
  }

  // App 在前台时也显示通知
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .list] }

  private func reopenPanel() {
    guard let openPanel else {
      pendingReopen = true
      return
    }
    pendingReopen = false
    windows.prepareToOpen()
    performance?.requestPanel()
    openPanel()
    NSApplication.shared.activate()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    model.prepareToQuit()
    Task {
      await model.finishQuitting()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct KayoiApp: App {
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(KayoiAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  init() {
    FSKitSpike.runIfRequested()
  }

  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model, closesOnOpen: true)
        .background(StatusItemCentering())
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    } label: {
      MenuBarStatusIcon(states: Array(model.connections.states.values))
        .background {
          if let probe = appDelegate.performance {
            PerformanceDrawProbe(probe: probe, role: .menu).accessibilityHidden(true)
          }
        }
        .task {
          appDelegate.configure(model: model) { openWindow(id: "main-panel") }
          // 设置里选的外观；演示模式指定了外观时由下面覆盖
          (model.preferences.string(forKey: AppAppearance.storageKey).flatMap(AppAppearance.init) ?? .system).apply()
          // 启动时就记下当前语言，之后在系统设置里改了也能提示重新打开
          _ = AppLanguage.atLaunch
          if model.options.isDemo, let appearance = DemoAppearance.name(options: model.options) {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
          }
          model.start()
          if let path = model.options.productShotPath {
            await DemoProductShot.write(model: model, to: path)
            return
          }
          if model.options.demoEditorKind != nil {
            appDelegate.windows.prepareToOpen()
            openWindow(id: "connection")
          }
          if model.options.demoWebService != nil {
            appDelegate.windows.prepareToOpen()
            openWindow(id: "demo-web-login")
          }
          if model.options.panelWindow {
            appDelegate.performance?.requestPanel()
            appDelegate.windows.prepareToOpen()
            openWindow(id: "main-panel")
          }
        }
    }.menuBarExtraStyle(.window)
    Window(L("Kayoi"), id: "main-panel") {
      PanelView(model: model)
        .defaultAppStorage(model.preferences)
        .background(WindowRegistration(coordinator: appDelegate.windows, role: "panel"))
        .background {
          if let probe = appDelegate.performance {
            PerformanceDrawProbe(probe: probe, role: .panel).accessibilityHidden(true)
          }
        }
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
        .toolbar(removing: .title)
        .task { model.start() }
    }.defaultSize(width: 380, height: 560).windowResizability(.contentSize)
      .defaultLaunchBehavior(.suppressed)
    Window(L("添加位置"), id: "connection") {
      ConnectionEditor(model: model).id(model.editing?.id)
        .background(WindowRegistration(coordinator: appDelegate.windows, role: "connection"))
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
        .toolbar(removing: .title)
    }.defaultSize(width: 576, height: 600).windowResizability(.contentSize)
      .defaultLaunchBehavior(.suppressed)
    Window(L("网页登录"), id: "demo-web-login") {
      if model.options.isDemo {
        DemoWebLoginWindow(options: model.options)
          .background(WindowRegistration(coordinator: appDelegate.windows, role: "web-login"))
          .containerBackground(KayoiTheme.background, for: .window)
          .tint(KayoiTheme.accent)
      }
    }.defaultSize(width: 720, height: 640).defaultLaunchBehavior(.suppressed)
    Settings {
      SettingsView(model: model)
        .background(WindowRegistration(coordinator: appDelegate.windows, role: "settings"))
        .defaultAppStorage(model.preferences)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.windowResizability(.contentSize)
      .commands {
        KayoiCommands(model: model, windows: appDelegate.windows)
        DemoCommands(model: model)
      }
  }
}

private struct DemoWebLoginWindow: View {
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var state: WebLoginState

  init(options: RuntimeOptions) {
    _state = State(
      initialValue: WebLoginState(
        service: options.demoWebService ?? .quark, options: options,
        validate: { _ in }, finish: { _ in }))
  }

  var body: some View {
    WebLoginView(state: state, cancel: { dismissWindow(id: "demo-web-login") })
  }
}
