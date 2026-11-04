import Core
import SwiftUI

@MainActor
final class KayoiAppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  let windows = WindowCoordinator()
  let performance = DemoPerformanceProbe(options: .current)
  private var openPanel: (() -> Void)?
  private var pendingReopen = false

  func configure(model: AppModel, openPanel: @escaping () -> Void) {
    self.model = model
    self.openPanel = openPanel
    windows.start()
    if pendingReopen { reopenPanel() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !windows.showExistingWindow() { reopenPanel() }
    return false
  }

  func applicationWillTerminate(_ notification: Notification) { windows.stop() }

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

@main struct KayoiApp: App {
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(KayoiAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow
  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
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
          if model.options.isDemo, let appearance = DemoAppearance.name(options: model.options) {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
          }
          model.start()
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
        .task { model.start() }
    }.defaultSize(width: 380, height: 560).windowResizability(.contentSize)
      .defaultLaunchBehavior(.suppressed)
    Window(L("添加位置"), id: "connection") {
      ConnectionEditor(model: model).id(model.editing?.id)
        .background(WindowRegistration(coordinator: appDelegate.windows, role: "connection"))
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 640, height: 640).defaultLaunchBehavior(
      .suppressed)
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
    Window(L("帮助"), id: "help") {
      HelpView()
        .background(WindowRegistration(coordinator: appDelegate.windows, role: "help"))
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 760, height: 600).windowResizability(.contentMinSize)
      .defaultLaunchBehavior(
        .suppressed
      )
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
