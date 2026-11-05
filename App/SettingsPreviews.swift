import SwiftUI

private struct SettingsDemoPreview: View {
  @State private var model: AppModel
  init(tab: String) {
    let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
    model.preferences.set(tab, forKey: "settings.selectedTab")
    _model = State(initialValue: model)
  }
  var body: some View {
    SettingsView(model: model).defaultAppStorage(model.preferences)
  }
}

#Preview("设置 · 通用 · 浅色") { SettingsDemoPreview(tab: "general").preferredColorScheme(.light) }
#Preview("设置 · 通用 · 深色") { SettingsDemoPreview(tab: "general").preferredColorScheme(.dark) }
#Preview("设置 · 通知 · 浅色") { SettingsDemoPreview(tab: "notifications").preferredColorScheme(.light) }
#Preview("设置 · 通知 · 深色") { SettingsDemoPreview(tab: "notifications").preferredColorScheme(.dark) }
#Preview("设置 · 空缓存 · 浅色") { SettingsDemoPreview(tab: "storage").preferredColorScheme(.light) }
#Preview("设置 · 空缓存 · 深色") { SettingsDemoPreview(tab: "storage").preferredColorScheme(.dark) }
#Preview("设置 · 安卓 · 浅色") { SettingsDemoPreview(tab: "android").preferredColorScheme(.light) }
#Preview("设置 · 安卓 · 深色") { SettingsDemoPreview(tab: "android").preferredColorScheme(.dark) }
#Preview("设置 · 关于 · 浅色") { SettingsDemoPreview(tab: "about").preferredColorScheme(.light) }
#Preview("设置 · 关于 · 深色") { SettingsDemoPreview(tab: "about").preferredColorScheme(.dark) }
