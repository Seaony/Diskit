import ADB
import AppKit
import Core
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @Bindable var model: AppModel
  @AppStorage("settings.selectedTab") private var selectedTab = "general"
  @AppStorage("notifications.mountFailure") private var notifyMountFailure = true
  @AppStorage("notifications.loginExpired") private var notifyLoginExpired = true
  @AppStorage("notifications.disconnect") private var notifyDisconnect = true
  @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
  @State private var language = AppLanguage.saved
  @State private var startsAtLogin = false
  @State private var loginNeedsApproval = false
  @State private var loginError: String?
  @State private var cacheBytes: Int64?
  @State private var checkingCache = false
  @State private var clearingCache = false
  @State private var confirmClear = false
  @State private var fingerprint = ""
  @State private var fingerprintError: String?
  @State private var regeneratingKey = false
  @State private var confirmKey = false
  @State private var copiedFingerprint = false
  @State private var copyFeedback: Task<Void, Never>?

  var body: some View {
    TabView(selection: $selectedTab) {
      generalPage
        .tabItem { Label(L("通用"), systemImage: "gearshape") }.tag("general")
      notificationsPage
        .tabItem { Label(L("通知"), systemImage: "bell") }.tag("notifications")
      storagePage
        .tabItem { Label(L("存储"), systemImage: "internaldrive") }.tag("storage")
      androidPage
        .tabItem { Label(L("Android"), systemImage: "smartphone") }.tag("android")
      aboutPage
        .tabItem { Label(L("关于"), systemImage: "info.circle") }.tag("about")
    }
    .frame(width: 560)
    // 工具栏下面的分隔线由各页自己画（见 settingsPageTop），关掉系统的，免得悬停时多出一条
    .background(EditorWindowAccessor { $0.titlebarSeparatorStyle = .none })
    .demoAppearanceEvidence("settings")
    .fixedSize(horizontal: false, vertical: true)
    .background(KayoiTheme.background)
    .buttonStyle(FlatButtonStyle())
    .toggleStyle(.switch)
    .controlSize(.small)
    .task(id: selectedTab) {
      switch selectedTab {
      case "general": refreshLogin()
      case "notifications": await model.refreshNotificationAuthorization()
      case "storage": await refreshCache()
      case "android": await refreshFingerprint()
      default: break
      }
    }
    .onAppear {
      if model.options.isDemo,
        let tab = model.options.demoSettingsTab,
        ["general", "notifications", "storage", "android", "about"].contains(tab)
      {
        selectedTab = tab
      }
    }
    .onDisappear {
      copyFeedback?.cancel()
      copyFeedback = nil
      copiedFingerprint = false
    }
    .alert(L("重新生成调试密钥？"), isPresented: $confirmKey) {
      Button(L("重新生成密钥"), role: .destructive) {
        model.operations.start { await regenerateKey() }
      }
      Button(L("取消"), role: .cancel) {}
    } message: {
      Text(L("重新生成后，下次连接每台手机时都需要重新允许这台 Mac。"))
    }
  }

  private var generalPage: some View {
    SettingsForm {
      KayoiFormSection {
        Toggle(L("开机自动启动"), isOn: Binding(get: { startsAtLogin }, set: setStartsAtLogin))
        if let loginError { inlineError(loginError) }
        if loginError != nil || loginNeedsApproval {
          Button(L("打开登录项设置")) {
            guard !model.options.isDemo else { return }
            SMAppService.openSystemSettingsLoginItems()
          }
          .help(L("在系统设置中允许 Kayoi 开机自动启动"))
        }
      } footer: {
        Text(L("退出 Kayoi 不会推出已挂载的共享"))
      }
      KayoiFormSection(title: L("外观与语言")) {
        KayoiSideRow {
          ChoiceButtons(
            options: AppAppearance.allCases.map(\.rawValue), selection: $appearance,
            title: { (AppAppearance(rawValue: $0) ?? .system).title },
            symbol: { (AppAppearance(rawValue: $0) ?? .system).symbol }
          )
          .accessibilityElement(children: .contain).accessibilityLabel(L("主题"))
        } label: {
          Text(L("主题")).accessibilityHidden(true)
        }
        .onChange(of: appearance) { _, value in (AppAppearance(rawValue: value) ?? .system).apply() }
        KayoiSideRow {
          ChoiceButtons(options: AppLanguage.allCases, selection: $language, title: \.title, symbol: \.symbol)
            // 书本图标会跟着地区换字形；按英文地区显示，English 用字母 A，简体中文已单独指定“字”
            .environment(\.locale, Locale(identifier: "en"))
            .accessibilityElement(children: .contain).accessibilityLabel(L("界面语言"))
        } label: {
          Text(L("界面语言")).accessibilityHidden(true)
        }
        // 演示模式不改真实的语言设置
        .onChange(of: language) { _, value in if !model.options.isDemo { value.save() } }
      } footer: {
        if language != AppLanguage.atLaunch {
          HStack(spacing: Space.sm) {
            Text(L("重新打开 Kayoi 后生效"))
            if !model.options.isDemo {
              Button(L("立即重新打开")) { AppLanguage.relaunch() }
            }
          }
        }
      }
      UpdateSettingsSection(updater: model.updates)
    }
  }

  private var notificationsPage: some View {
    SettingsForm {
      KayoiFormSection(title: L("系统权限")) {
        notificationPermission
      }
      KayoiFormSection(title: L("通知时机")) {
        Toggle(L("挂载失败"), isOn: $notifyMountFailure)
        Toggle(L("登录过期"), isOn: $notifyLoginExpired)
        Toggle(L("位置意外断开"), isOn: $notifyDisconnect)
      } footer: {
        Text(L("只在挂载失败、登录过期或位置意外断开时通知。"))
      }
    }
  }

  private var storagePage: some View {
    SettingsForm {
      KayoiFormSection(title: L("本机缓存")) {
        KayoiSideRow(L("当前占用")) {
          if checkingCache {
            ProgressView().nativeProgressAppearance().controlSize(.mini).accessibilityLabel(L("正在计算缓存大小…"))
          } else if let cacheBytes {
            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
              .monospacedDigit()
          } else {
            Text(L("尚未计算")).foregroundStyle(KayoiTheme.secondaryText)
          }
        }
        if confirmClear {
          VStack(alignment: .leading, spacing: Space.sm) {
            Text(L("清空本机缓存？"))
              .font(.body.weight(.semibold))
            Text(L("只会删除 Kayoi 的本机缓存，设备和网盘中的文件不受影响。"))
              .font(.caption).foregroundStyle(KayoiTheme.secondaryText)
            HStack {
              Button(L("取消")) { confirmClear = false }
              Button(L("清空缓存"), role: .destructive) {
                confirmClear = false
                clearingCache = true
                model.operations.start {
                  await model.clearCache()
                  clearingCache = false
                  await refreshCache()
                }
              }
            }
          }
        } else {
          HStack {
            Button(L("清空缓存…")) { confirmClear = true }
              .disabled(clearingCache || checkingCache || cacheBytes == nil || cacheBytes == 0)
              .help(cacheBytes == 0 ? L("没有可清理的本机缓存") : L("清理 Kayoi 留下的本机缓存"))
            if clearingCache { ProgressView().nativeProgressAppearance().controlSize(.mini) }
          }
        }
      } footer: {
        Text(L("当前版本不缓存远端文件；这里可清理以前留下的本机缓存。系统挂载的共享不使用此缓存。"))
      }
    }
  }

  private var androidPage: some View {
    SettingsForm {
      KayoiFormSection(title: L("USB 调试密钥")) {
        if fingerprint.isEmpty {
          if let fingerprintError {
            inlineError(fingerprintError)
            Button(L("重试")) { model.operations.start { await refreshFingerprint() } }
          } else {
            ProgressView().nativeProgressAppearance().controlSize(.small).accessibilityLabel(L("正在读取密钥指纹…"))
          }
        } else {
          KayoiSideRow(L("ADB 密钥指纹")) {
            Text(fingerprint)
              .font(.body.monospaced()).monospacedDigit()
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack {
            Button(copiedFingerprint ? L("已复制") : L("复制指纹"), action: copyFingerprint)
              .disabled(regeneratingKey)
            Button(L("重新生成密钥…")) { confirmKey = true }
              .disabled(regeneratingKey)
            if regeneratingKey { ProgressView().nativeProgressAppearance().controlSize(.mini) }
          }
          if let fingerprintError { inlineError(fingerprintError) }
        }
      } footer: {
        Text(L("MD5 指纹用于核对手机上的 USB 调试授权提示；请确认两边一致后再允许。"))
      }
      KayoiFormSection(title: L("设备连接")) {
        Text(L("如果提示设备被占用，请退出其它手机调试工具，再重试；必要时重新启动 Kayoi。"))
          .font(.callout).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // 关于：居中放图标、名称、版本和检查更新
  private var aboutPage: some View {
    VStack(spacing: Space.lg) {
      // 直接取资源里的图标，不用系统缓存的应用图标，换图标后这里马上跟着变
      Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
        .resizable().interpolation(.high).frame(width: 96, height: 96)
        .accessibilityHidden(true)
      VStack(spacing: Space.xs) {
        Text(verbatim: "Kayoi").font(.system(size: 20, weight: .semibold))
          .foregroundStyle(KayoiTheme.primaryText)
        Text(LF("版本 %@", version)) + Text(verbatim: " · ") + Text(LF("构建 %@", build))
      }
      .font(.callout).monospacedDigit().foregroundStyle(KayoiTheme.secondaryText)
      UpdateCheckView(updater: model.updates, showLogs: model.showLogs)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Space.section)
    .settingsPageTop()
    .background(KayoiTheme.background)
  }

  @ViewBuilder private var notificationPermission: some View {
    if model.notificationAuthorization == .authorized
      || model.notificationAuthorization == .provisional
    {
      Label(L("系统通知已允许"), systemImage: "bell.fill")
        .foregroundStyle(KayoiTheme.secondaryText)
    } else if model.notificationAuthorization == .denied {
      KayoiSideRow {
        Button(L("打开系统设置")) { model.openNotificationSettings() }
      } label: {
        Label(L("系统通知已关闭"), systemImage: "bell.slash")
      }
    } else {
      KayoiSideRow {
        Button(L("允许通知")) {
          model.operations.start { await model.requestNotificationAuthorization() }
        }
      } label: {
        Label(L("尚未允许系统通知"), systemImage: "bell")
      }
    }
  }

  private func setStartsAtLogin(_ enabled: Bool) {
    if model.options.isDemo {
      if let error = model.options.demoLoginItem?.errorMessage { loginError = error }
      else { startsAtLogin = enabled; loginError = nil }
      return
    }
    loginError = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch { loginError = HumanError.detail(error) }
    refreshLogin()
  }

  private func refreshLogin() {
    if model.options.isDemo {
      if let state = model.options.demoLoginItem {
        startsAtLogin = state.isEnabled
        loginNeedsApproval = state == .requiresApproval
        loginError = state.errorMessage
      }
      return
    }
    startsAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
  }

  private func refreshCache() async {
    checkingCache = true
    let size = await model.cacheSize()
    guard !Task.isCancelled else { return }
    cacheBytes = size
    checkingCache = false
  }

  private func refreshFingerprint() async {
    if model.options.isDemo {
      fingerprint = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"
      fingerprintError = nil
      return
    }
    let secrets = model.secrets
    do {
      let value = try await Task.detached(priority: .utility) {
        try ADBIdentity(store: secrets).fingerprint()
      }.value
      guard !Task.isCancelled else { return }
      fingerprint = value
      fingerprintError = nil
    } catch { fingerprintError = HumanError.detail(error) }
  }

  private func regenerateKey() async {
    regeneratingKey = true
    defer { regeneratingKey = false }
    do {
      if !model.options.isDemo {
        let secrets = model.secrets
        try await Task.detached(priority: .utility) { try ADBIdentity(store: secrets).regenerate() }
          .value
      }
      await refreshFingerprint()
    } catch { fingerprintError = HumanError.detail(error) }
  }

  private func copyFingerprint() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(fingerprint, forType: .string)
    copyFeedback?.cancel()
    copiedFingerprint = true
    copyFeedback = Task {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      copiedFingerprint = false
    }
  }

  private func inlineError(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle.fill")
      .font(.caption).foregroundStyle(KayoiTheme.error)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
  }
  private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2" }
}

// 设置各页：和添加表单一样的带边框分组卡片；分组下面常有说明文字，间距比添加表单多一档
private struct SettingsForm<Content: View>: View {
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xl) { content }
      .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
      .labeledContentStyle(KayoiFormRowStyle()).toggleStyle(KayoiFormSwitchStyle())
      .controlSize(.regular)
      .settingsPageTop()
      .fixedSize(horizontal: false, vertical: true)
      .background(KayoiTheme.background)
  }
}

extension View {
  // 设置各页顶部固定一条分隔线；系统的那条只在光标移到可滚动区域时才出现，这里关掉它
  fileprivate func settingsPageTop() -> some View {
    scrollEdgeEffectHidden(true, for: .top)
      // 工具栏底色每页都显示，不随页面能否滚动变化
      .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
      .overlay(alignment: .top) { KayoiSeparator() }
  }
}
