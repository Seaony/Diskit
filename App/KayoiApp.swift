import Core
import SwiftUI

@main struct KayoiApp: App {
  @State private var model = AppModel()
  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
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
    }.defaultSize(width: 460, height: 480).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
    Window("设置", id: "settings") {
      SettingsView(model: model)
    }.defaultSize(width: 460, height: 320).windowResizability(.contentSize).defaultLaunchBehavior(
      .suppressed)
  }
}
