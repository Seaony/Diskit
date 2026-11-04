import Core
import Quark
import SwiftUI
import WebKit

struct ServiceWebLogin: NSViewRepresentable {
  let state: WebLoginState

  func makeCoordinator() -> Coordinator { Coordinator(state: state) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "kayoiWebLogin")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebLoginObservationScript.source(service: state.service),
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let view = WKWebView(frame: .zero, configuration: configuration)
    if state.service == .quark { view.customUserAgent = QuarkCloudConfiguration.quark.userAgent }
    if state.service == .uc { view.customUserAgent = QuarkCloudConfiguration.uc.userAgent }
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    context.coordinator.attach(view)
    // 演示分支在外层使用原生本地内容，此处仍拒绝发起外部请求。
    if !state.options.isDemo {
      view.load(
        URLRequest(url: state.service.loginURL, timeoutInterval: RemoteTimeout.cloudRequest))
    }
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    guard !state.options.isDemo, context.coordinator.reloadID != state.reloadID else { return }
    context.coordinator.reloadID = state.reloadID
    view.load(URLRequest(url: state.service.loginURL, timeoutInterval: RemoteTimeout.cloudRequest))
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    coordinator.stop()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "kayoiWebLogin")
    view.configuration.userContentController.removeAllUserScripts()
  }

  @MainActor
  final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler
  {
    let state: WebLoginState
    var reloadID: Int
    private var store: WKHTTPCookieStore?
    private var progressObservation: NSKeyValueObservation?
    private var active = true

    init(state: WebLoginState) {
      self.state = state
      reloadID = state.reloadID
    }

    func attach(_ view: WKWebView) {
      store = view.configuration.websiteDataStore.httpCookieStore
      store?.add(self)
      progressObservation = view.observe(\.estimatedProgress, options: [.initial, .new]) {
        [weak self] _, change in
        let progress = change.newValue ?? 0
        Task { @MainActor in
          guard let self, self.active else { return }
          self.state.progress = progress
        }
      }
    }

    func stop() {
      active = false
      store?.remove(self)
      store = nil
      progressObservation = nil
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspectCookies(cookieStore) }

    private func inspectCookies(_ cookieStore: WKHTTPCookieStore) {
      guard active, !state.options.isDemo else { return }
      let service = state.service
      cookieStore.getAllCookies { [weak self] cookies in
        guard let credentials = WebLoginCredentialParser.cookies(cookies, service: service) else {
          return
        }
        Task { @MainActor in
          guard let self, self.active else { return }
          self.state.capture(credentials)
        }
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard active, !state.options.isDemo, message.frameInfo.isMainFrame,
        state.service.allows(message.frameInfo.request.url),
        let values = message.body as? [String: String],
        let authorization = values["authorization"],
        let credentials = WebLoginCredentialParser.authorization(
          authorization, service: state.service, phone: values["phone"],
          userDomainID: values["userDomainID"])
      else { return }
      state.capture(credentials)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      guard active else { return }
      state.isLoading = true
      state.loadError = nil
      state.pageURL = webView.url
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      guard active else { return }
      state.pageURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard active else { return }
      state.isLoading = false
      state.progress = 1
      state.pageURL = webView.url
      if let store { inspectCookies(store) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      failed(error)
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { failed(error) }
    private func failed(_ error: Error) {
      guard active, (error as NSError).code != NSURLErrorCancelled else { return }
      state.isLoading = false
      state.loadError = HumanError.detail(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
      -> WKNavigationActionPolicy
    {
      guard !state.options.isDemo, let url = navigationAction.request.url,
        url.scheme?.lowercased() == "https", url.user == nil, url.password == nil
      else { return .cancel }
      return .allow
    }

    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil,
        navigationAction.request.url?.scheme?.lowercased() == "https"
      {
        webView.load(navigationAction.request)
      }
      return nil
    }
  }
}

#Preview("网页容器 · 离线空态 · 浅色") {
  WebLoginPreview(scenario: "web-empty")
    .frame(width: 560, height: 520).preferredColorScheme(.light)
}

#Preview("网页容器 · 离线空态 · 深色") {
  WebLoginPreview(scenario: "web-empty")
    .frame(width: 560, height: 520).preferredColorScheme(.dark)
}
