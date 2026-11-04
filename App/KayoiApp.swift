import Core
import SwiftUI

@MainActor
final class KayoiAppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    let mounts = model.connections.mountsToEjectOnQuit
    guard !mounts.isEmpty else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = L("退出 Kayoi？")
    alert.informativeText = String.localizedStringWithFormat(
      L("退出前会推出：%@。SMB 共享不受影响。"),
      mounts.map(\.name).joined(separator: L("、")))
    alert.addButton(withTitle: L("退出并推出位置"))
    alert.addButton(withTitle: L("取消"))
    guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    Task {
      for connection in mounts {
        await model.connections.toggle(connection)
      }
      model.connections.refreshMounts()
      let remaining = model.connections.mountsToEjectOnQuit
      guard remaining.isEmpty else {
        let failure = NSAlert()
        failure.messageText = L("有位置未能推出")
        failure.informativeText = String.localizedStringWithFormat(
          L("“%@”仍在挂载。请关闭正在使用其中文件的应用，然后重试退出。"),
          remaining.map(\.name).joined(separator: L("、")))
        failure.addButton(withTitle: L("好"))
        failure.runModal()
        sender.reply(toApplicationShouldTerminate: false)
        return
      }
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
      Image(systemName: model.connections.mountedCount > 0 ? "externaldrive.fill" : "externaldrive")
        .accessibilityHidden(true)
        .frame(width: 18, height: 18)
        .overlay(alignment: .bottomTrailing) {
          if model.connections.mountedCount > 0 {
            Circle().fill(.primary).frame(width: 4, height: 4).offset(x: 1, y: 1)
              .accessibilityHidden(true)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          model.connections.mountedCount > 0
            ? String.localizedStringWithFormat(
              L("Kayoi，%d 个位置已挂载"), model.connections.mountedCount)
            : L("Kayoi，没有挂载的位置")
        )
        .task {
          appDelegate.model = model
          model.start()
        }
    }.menuBarExtraStyle(.window)
    Window(model.editing == nil ? L("添加位置") : L("编辑位置"), id: "connection") {
      ConnectionEditor(model: model).id(model.editing?.id)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 600, height: 660).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
    Window("设置", id: "settings") {
      SettingsView(model: model)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 600, height: 680).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
    Window("帮助", id: "help") {
      HelpView()
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 560, height: 620).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed
    )
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(L("添加位置")) {
          model.editing = nil
          openWindow(id: "connection")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }.keyboardShortcut("n", modifiers: .command)
      }
      CommandGroup(replacing: .appSettings) {
        Button(L("设置")) {
          openWindow(id: "settings")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",", modifiers: .command)
        Button(L("Kayoi 帮助")) {
          openWindow(id: "help")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }.keyboardShortcut("?", modifiers: .command)
      }
    }
  }
}
