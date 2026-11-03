import ADB
import Core
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @AppStorage("cacheLimitGB") private var cacheLimitGB = 5
  @State private var startsAtLogin = false
  @State private var loginNeedsApproval = false
  @State private var cacheBytes: Int64 = 0
  @State private var confirmClear = false
  @State private var fingerprint = ""
  @State private var confirmKey = false
  @State private var error: String?
  var body: some View {
    Form {
      Section("通用") {
        Toggle(
          "开机自动启动",
          isOn: Binding(
            get: { startsAtLogin },
            set: { enabled in
              do {
                if enabled {
                  try SMAppService.mainApp.register()
                } else {
                  try SMAppService.mainApp.unregister()
                }
                refreshLogin()
              } catch {
                self.error = error.localizedDescription
                refreshLogin()
              }
            }))
        if loginNeedsApproval {
          Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
        }
      }
      Section("缓存") {
        LabeledContent(
          "当前占用", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
        Stepper(value: $cacheLimitGB, in: 1...1024) {
          Text(String(format: L("缓存上限：%d GB"), cacheLimitGB))
        }
        Button("清空缓存") { confirmClear = true }
      }
      Section("ADB") {
        Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true).accessibilityLabel(
            L("ADB 密钥指纹") + ": " + fingerprint)
        Button("重新生成密钥") { confirmKey = true }
        Text("若提示设备被占用，请先退出其它 adb 程序或执行 adb kill-server。").font(.caption).foregroundStyle(
          .secondary)
      }
      Section("日志") { Button("在 Finder 中显示日志") { model.showLogs() } }
      if let error { Text(error).foregroundStyle(.red) }
    }.formStyle(.grouped).buttonStyle(FlatButtonStyle()).toggleStyle(.checkbox)
      .scrollContentBackground(.hidden)
      .background(KayoiTheme.background)
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          Text("设置").font(.system(size: 23, weight: .semibold))
          Text("管理启动、缓存与设备密钥").font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
          .background(KayoiTheme.background)
          .overlay(alignment: .bottom) { Divider() }
      }
      .frame(width: 560, height: 560)
      .onAppear {
        do { fingerprint = try ADBIdentity().fingerprint() } catch {
          self.error = error.localizedDescription
        }
        refreshLogin()
        cacheBytes = model.cacheSize()
      }
      .confirmationDialog("重新生成后，所有手机都需要重新授权。", isPresented: $confirmKey) {
        Button("重新生成密钥", role: .destructive) {
          do {
            try ADBIdentity().regenerate()
            fingerprint = try ADBIdentity().fingerprint()
          } catch { self.error = error.localizedDescription }
        }
      }
      .confirmationDialog("清空缓存前需要推出全部卷，是否继续？", isPresented: $confirmClear) {
        Button("推出并清空缓存", role: .destructive) {
          Task {
            await model.clearCache()
            cacheBytes = model.cacheSize()
          }
        }
      }
  }
  private func refreshLogin() {
    startsAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
  }
}
