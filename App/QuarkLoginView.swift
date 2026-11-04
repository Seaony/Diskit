import Core
import Quark
import SwiftUI
import WebKit

struct QuarkLoginView: View {
  let session: QuarkSession
  let onSuccess: (QuarkAccount) -> Void
  let onCancel: () -> Void
  @State private var manual = false
  @State private var cookie = ""
  @State private var error: String?
  @State private var checking = false
  @State private var pending: (String, Bool)?
  @State private var validation: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(
            session.configuration.service == .uc ? L("登录 UC 网盘") : L("登录夸克网盘")
          ).font(.headline)
          Text(L("请在网页中扫码登录。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(L("取消"), action: onCancel)
      }
      Label(L("非官方接口，可能随时失效"), systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange)
      QuarkWebLogin(
        url: session.configuration.loginURL,
        cookieDomain: session.configuration.cookieDomain,
        userAgent: session.configuration.userAgent,
        onCookie: { enqueue($0, manual: false) }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .layoutPriority(1)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(KayoiTheme.border) }
      if checking { ProgressView(L("正在验证账号…")).controlSize(.small) }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      DisclosureGroup(L("其他登录方式"), isExpanded: $manual) {
        VStack(alignment: .leading, spacing: 8) {
          Text(L("如果二维码无法显示，可以从浏览器复制夸克网盘的登录信息并粘贴到这里。不要把它发给其他人。"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            SecureField(L("粘贴登录信息"), text: $cookie)
            Button(L("使用此登录信息")) { enqueue(cookie, manual: true) }.disabled(
              cookie.isEmpty || checking)
          }
        }.padding(.top, 8)
      }
    }.buttonStyle(FlatButtonStyle()).padding(20)
      .frame(width: 600, height: 640)
      .background(KayoiTheme.background).onDisappear { validation?.cancel() }
  }
  private func enqueue(_ value: String, manual: Bool) {
    pending = (value, manual)
    guard !checking else { return }
    checking = true
    validation = Task { @MainActor in
      defer { checking = false }
      while let (candidate, manual) = pending {
        pending = nil
        do {
          let account = try await session.login(cookie: candidate)
          try Task.checkCancellation()
          onSuccess(account)
          return
        } catch {
          if Task.isCancelled { return }
          if manual || (error as? QuarkError) != .loginRequired {
            self.error = error.localizedDescription
          }
        }
      }
    }
  }
}

private struct QuarkWebLogin: NSViewRepresentable {
  let url: URL
  let cookieDomain: String
  let userAgent: String
  let onCookie: (String) -> Void
  func makeCoordinator() -> Coordinator {
    Coordinator(cookieDomain: cookieDomain, onCookie: onCookie)
  }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = userAgent
    view.uiDelegate = context.coordinator
    context.coordinator.start(configuration.websiteDataStore.httpCookieStore)
    view.load(URLRequest(url: url))
    return view
  }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.stopLoading()
    coordinator.stop()
    nsView.uiDelegate = nil
  }
  @MainActor
  final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKUIDelegate {
    private let onCookie: (String) -> Void
    private let cookieDomain: String
    private var store: WKHTTPCookieStore?
    private var active = false
    private var lastHeader: String?
    init(cookieDomain: String, onCookie: @escaping (String) -> Void) {
      self.cookieDomain = cookieDomain
      self.onCookie = onCookie
    }
    func start(_ store: WKHTTPCookieStore) {
      self.store = store
      active = true
      store.add(self)
    }
    func stop() {
      active = false
      store?.remove(self)
      store = nil
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
      guard active else { return }
      cookieStore.getAllCookies { cookies in
        guard
          let header = QuarkWebCookies.header(from: cookies, domain: self.cookieDomain)
        else { return }
        Task { @MainActor in
          guard self.active, self.lastHeader != header else { return }
          self.lastHeader = header
          self.onCookie(header)
        }
      }
    }
    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
      return nil
    }
  }
}
