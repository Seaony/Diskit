import Core
import SwiftUI

@main struct KayoiApp: App {
  @State private var model = AppModel()
  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    } label: {
      Image(systemName: "externaldrive")
        .overlay(alignment: .bottomTrailing) {
          if model.connections.mountedCount > 0 { Circle().frame(width: 4, height: 4) }
        }
        .accessibilityLabel("Kayoi")
        .task { model.start() }
    }.menuBarExtraStyle(.window)
    Window("添加或编辑位置", id: "connection") {
      ConnectionEditor(model: model).id(model.editing?.id)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 560, height: 500).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
    Window("设置", id: "settings") {
      SettingsView(model: model)
        .containerBackground(KayoiTheme.background, for: .window)
        .tint(KayoiTheme.accent)
    }.defaultSize(width: 560, height: 560).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
  }
}
