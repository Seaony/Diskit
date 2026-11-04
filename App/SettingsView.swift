import ADB
import AppKit
import Core
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @Bindable var model: AppModel
  @AppStorage("cacheLimitGB") private var cacheLimitGB = 5
  @AppStorage("notifications.mountFailure") private var notifyMountFailure = true
  @AppStorage("notifications.loginExpired") private var notifyLoginExpired = true
  @AppStorage("notifications.disconnect") private var notifyDisconnect = true
  @State private var startsAtLogin = false
  @State private var loginNeedsApproval = false
  @State private var loginError: String?
  @State private var cacheBytes: Int64 = 0
  @State private var confirmClear = false
  @State private var fingerprint = ""
  @State private var fingerprintError: String?
  @State private var confirmKey = false
  @State private var copiedFingerprint = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L("设置")).font(.system(size: 23, weight: .semibold))
        Text(L("管理启动、通知、缓存与设备密钥"))
          .font(.subheadline).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 24).padding(.vertical, 16)
      Divider()

      Form {
        Section(L("通用")) {
          Toggle(
            L("开机自动启动"),
            isOn: Binding(
              get: { startsAtLogin },
              set: { enabled in
                loginError = nil
                do {
                  if enabled {
                    try SMAppService.mainApp.register()
                  } else {
                    try SMAppService.mainApp.unregister()
                  }
                } catch {
                  loginError = error.localizedDescription
                }
                refreshLogin()
              }))
          if let loginError {
            inlineError(loginError)
          }
          if loginNeedsApproval {
            Button(L("在系统设置中允许登录项")) {
              SMAppService.openSystemSettingsLoginItems()
            }
          }
        }

        Section(L("通知")) {
          Text(L("只在挂载失败、登录过期或位置意外断开时通知。"))
            .font(.caption).foregroundStyle(.secondary)
          Toggle(L("挂载失败"), isOn: $notifyMountFailure)
          Toggle(L("登录需要更新"), isOn: $notifyLoginExpired)
          Toggle(L("位置意外断开"), isOn: $notifyDisconnect)
          notificationPermission
        }

        Section(L("缓存")) {
          LabeledContent(
            L("当前占用"),
            value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
          Stepper(value: $cacheLimitGB, in: 1...1024) {
            Text(String.localizedStringWithFormat(L("缓存上限：%d GB"), cacheLimitGB))
          }
          Text(L("SMB 系统挂载不使用这里的缓存。清理不会推出 SMB 共享。"))
            .font(.caption).foregroundStyle(.secondary)
          Button(L("清空缓存")) { confirmClear = true }
        }

        Section(L("安卓调试密钥")) {
          if fingerprint.isEmpty {
            if let fingerprintError { inlineError(fingerprintError) }
          } else {
            Text(fingerprint)
              .font(.caption.monospaced()).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel(L("ADB 密钥指纹") + ": " + fingerprint)
            HStack {
              Button(copiedFingerprint ? L("已复制") : L("复制指纹")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fingerprint, forType: .string)
                copiedFingerprint = true
              }
              Button(L("重新生成密钥")) { confirmKey = true }
            }
            Text(L("连接新手机时，手机上会显示这个指纹。指纹应与这里一致。"))
              .font(.caption).foregroundStyle(.secondary)
          }
          Text(L("如果提示设备被占用，请退出其它手机调试工具，再重试；必要时重新启动 Kayoi。"))
            .font(.caption).foregroundStyle(.secondary)
        }

        Section(L("日志")) {
          Button(L("在 Finder 中显示日志")) { model.showLogs() }
          Text(L("日志会保留最近 7 天，不会记录密码、令牌或私钥。"))
            .font(.caption).foregroundStyle(.secondary)
        }

        Section(L("关于")) {
          LabeledContent(L("版本"), value: version)
          HStack {
            Button(L("查看致谢与第三方许可证")) {
              openBundled("THIRD_PARTY_NOTICES", extension: "md")
            }
            Button(L("查看 Apache 2.0 许可证")) {
              openBundled("Apache-2.0", extension: "txt")
            }
          }
          Text(L("Kayoi 使用系统文件服务连接设备和服务，不上传你的文件内容。"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
    .buttonStyle(FlatButtonStyle())
    .toggleStyle(.checkbox)
    .background(KayoiTheme.background)
    .frame(width: 600, height: 680)
    .onAppear {
      refreshLogin()
      refreshFingerprint()
      model.enforceCacheLimit()
      cacheBytes = model.cacheSize()
      Task { await model.refreshNotificationAuthorization() }
    }
    .onChange(of: cacheLimitGB) { _, _ in
      model.enforceCacheLimit()
      cacheBytes = model.cacheSize()
    }
    .confirmationDialog(
      L("重新生成调试密钥？"),
      isPresented: $confirmKey
    ) {
      Button(L("重新生成密钥"), role: .destructive) {
        do {
          try ADBIdentity().regenerate()
          refreshFingerprint()
        } catch { fingerprintError = HumanError.detail(error) }
      }
    } message: {
      Text(L("所有已授权的手机都会断开。下次连接时，需要在每台手机上重新允许这台 Mac。"))
    }
    .confirmationDialog(
      L("清空缓存？"),
      isPresented: $confirmClear
    ) {
      Button(L("清空缓存"), role: .destructive) {
        Task {
          await model.clearCache()
          cacheBytes = model.cacheSize()
        }
      }
    } message: {
      Text(L("Kayoi 会先推出正在使用文件缓存的卷。SMB 共享不会推出，设备上的文件不会删除。"))
    }
  }

  @ViewBuilder private var notificationPermission: some View {
    if notificationsAreAllowed {
      Label(L("系统通知已允许"), systemImage: "checkmark.circle.fill")
        .font(.caption).foregroundStyle(KayoiTheme.accent)
    } else if model.notificationAuthorization == .denied {
      HStack {
        Text(L("系统通知已关闭。")).font(.caption).foregroundStyle(.secondary)
        Button(L("打开通知设置")) { model.openNotificationSettings() }
      }
    } else {
      HStack {
        Text(L("允许系统通知后，上面的开关才会生效。"))
          .font(.caption).foregroundStyle(.secondary)
        Button(L("允许系统通知")) {
          Task { await model.requestNotificationAuthorization() }
        }
      }
    }
  }

  private var notificationsAreAllowed: Bool {
    model.notificationAuthorization == .authorized
      || model.notificationAuthorization == .provisional
  }

  private func refreshLogin() {
    startsAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
  }

  private func refreshFingerprint() {
    do {
      fingerprint = try ADBIdentity().fingerprint()
      fingerprintError = nil
    } catch {
      fingerprintError = HumanError.detail(error)
    }
  }

  private func inlineError(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle.fill")
      .font(.caption).foregroundStyle(.red)
  }

  private func openBundled(_ name: String, extension fileExtension: String) {
    guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(short) (\(build))"
  }
}
