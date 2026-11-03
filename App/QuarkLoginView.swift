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
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("扫码登录夸克网盘").font(.headline)
        Spacer()
        Button("取消", action: onCancel)
      }
      Text("非官方接口，可能随时失效").font(.caption).foregroundStyle(.secondary)
      QuarkWebLogin(onCookie: { enqueue($0, manual: false) }).frame(width: 680, height: 480)
      if checking { ProgressView("正在验证账号…").controlSize(.small) }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      DisclosureGroup("手动粘贴 Cookie", isExpanded: $manual) {
        HStack {
          SecureField("Cookie", text: $cookie)
          Button("使用此 Cookie") { enqueue(cookie, manual: true) }.disabled(
            cookie.isEmpty || checking)
        }.padding(.top, 8)
      }
    }.buttonStyle(FlatButtonStyle()).padding(20)
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
  let onCookie: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(onCookie: onCookie) }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = QuarkSession.userAgent
    view.uiDelegate = context.coordinator
    context.coordinator.start(configuration.websiteDataStore.httpCookieStore)
    view.load(URLRequest(url: URL(string: "https://pan.quark.cn/")!))
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
    private var store: WKHTTPCookieStore?
    private var active = false
    private var lastHeader: String?
    init(onCookie: @escaping (String) -> Void) { self.onCookie = onCookie }
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
        guard let header = QuarkWebCookies.header(from: cookies) else { return }
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
