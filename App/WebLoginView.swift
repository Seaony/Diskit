import Core
import SwiftUI

struct WebLoginView: View {
  @Bindable var state: WebLoginState
  let cancel: () -> Void
  @State private var manual = false
  @State private var pasted = ""
  @State private var manualError: String?

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 16) {
          Text(
            LF("请在下方登录%@。", state.service.name)
          )
          .font(.body).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button(L("取消"), action: cancel).keyboardShortcut(.cancelAction)
        }
        Label(state.pageURL?.host ?? state.service.domain, systemImage: "lock.shield")
          .font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityLabel(
            LF("当前网页：%@", state.pageURL?.host ?? state.service.domain))
      }.padding(20)
      if state.isLoading {
        ProgressView(value: state.progress).nativeLinearProgressAppearance()
          .accessibilityLabel(L("正在加载登录网页"))
      } else {
        Divider()
      }
      ZStack {
        if state.options.isDemo { demoPage } else { ServiceWebLogin(state: state) }
        if let error = state.loadError {
          VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).accessibilityHidden(true)
            Text(L("登录网页未能加载")).font(.headline)
            ScrollView {
              Text(error).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(maxHeight: 160)
            Button(L("重新加载")) { state.reload() }
          }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DiskitTheme.background)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        if state.checking { ProgressView(L("正在验证登录信息…")).nativeProgressAppearance().controlSize(.small) }
        if let error = state.validationError ?? manualError {
          HStack(alignment: .top, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(DiskitTheme.error).lineLimit(3).help(error)
            Spacer(minLength: 0)
            if state.validationError != nil {
              Button(L("重试")) { state.retryValidation() }.disabled(state.checking)
            }
          }
        }
        DisclosureGroup(L("其他登录方式…"), isExpanded: $manual) {
          VStack(alignment: .leading, spacing: 8) {
            Text(manualInstructions).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              SecureField(L("粘贴登录信息"), text: $pasted)
              Button(L("使用此登录信息"), action: useManual)
                .disabled(
                  pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.checking)
            }
          }.padding(.top, 8)
        }
      }.padding(20)
    }.background(DiskitTheme.background).buttonStyle(FlatButtonStyle())
      .frame(minWidth: 560, minHeight: 520)
  }

  private var demoPage: some View {
    VStack(spacing: 20) {
      Image(systemName: state.options.scenario == "web-success" ? "checkmark.circle" : "person.crop.circle.badge.checkmark")
        .font(.largeTitle).accessibilityHidden(true)
      Text(state.service.name).font(.title2)
      Text(state.options.scenario == "web-success"
        ? L("登录成功，登录窗口将自动关闭。")
        : L("这是离线演示页面，不会连接服务商或读取真实账号。"))
        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if state.options.scenario != "web-empty", state.options.scenario != "web-success" {
        Button(L("模拟登录成功")) { state.demonstrateSuccess() }
          .disabled(state.checking).accessibilityIdentifier("demo.web-login.complete")
        Button(L("模拟加载失败")) { state.demonstrateFailure() }
          .accessibilityIdentifier("demo.web-login.fail")
      }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(DiskitTheme.surface)
  }

  private var manualInstructions: String {
    switch state.service {
    case .mobile:
      L("在移动云盘网页完成登录后，从浏览器开发者工具的网络请求中复制 Authorization 请求头，保留 Basic 前缀或只粘贴后面的内容。")
    case .xunlei:
      L("在迅雷云盘网页完成登录后，从浏览器开发者工具的网络请求中复制 Authorization 请求头，保留 Token 前缀或只粘贴后面的内容。")
    default:
      LF("在%@网页完成登录后，从浏览器开发者工具的网络请求中复制 Cookie 请求头，再粘贴到这里。", state.service.name)
    }
  }

  private func useManual() {
    guard let credentials = WebLoginCredentialParser.manual(pasted, service: state.service) else {
      manualError = L("登录信息格式不正确，请重新复制完整内容。")
      return
    }
    manualError = nil
    state.capture(credentials, manual: true)
  }
}

// 预览只展示本地状态，不创建网页或发起登录。
struct WebLoginPreview: View {
  let scenario: String
  var service: WebLoginService = .quark

  var body: some View {
    WebLoginView(state: previewState, cancel: {})
  }

  private var previewState: WebLoginState {
    let state = WebLoginState(
      service: service,
      options: RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": scenario]),
      validate: { _ in }, finish: { _ in })
    if scenario == "web-validation-error" {
      state.validationError = L("登录信息已失效，请重新登录。")
    }
    return state
  }
}

#Preview("网页登录 · 就绪 · 浅色") {
  WebLoginPreview(scenario: "web-ready", service: .quark)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 就绪 · 深色") {
  WebLoginPreview(scenario: "web-ready", service: .quark)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}

#Preview("网页登录 · 空状态 · 浅色") {
  WebLoginPreview(scenario: "web-empty", service: .uc)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 空状态 · 深色") {
  WebLoginPreview(scenario: "web-empty", service: .uc)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}

#Preview("网页登录 · 加载中 · 浅色") {
  WebLoginPreview(scenario: "web-loading", service: .mobile)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 加载中 · 深色") {
  WebLoginPreview(scenario: "web-loading", service: .mobile)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}

#Preview("网页登录 · 加载失败 · 浅色") {
  WebLoginPreview(scenario: "web-error", service: .xunlei)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 加载失败 · 深色") {
  WebLoginPreview(scenario: "web-error", service: .xunlei)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}

#Preview("网页登录 · 验证失败 · 浅色") {
  WebLoginPreview(scenario: "web-validation-error", service: .lanzou)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 验证失败 · 深色") {
  WebLoginPreview(scenario: "web-validation-error", service: .lanzou)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}

#Preview("网页登录 · 成功 · 浅色") {
  WebLoginPreview(scenario: "web-success", service: .tianyi)
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页登录 · 成功 · 深色") {
  WebLoginPreview(scenario: "web-success", service: .tianyi)
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}
