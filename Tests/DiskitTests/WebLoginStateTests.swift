import Core
import Foundation
import Testing

private struct WebLoginExpiredFixture: LoginRequiredFailure {
  let requiresLogin = true
}

@MainActor @Test func webLoginAutomaticExpiryStaysQuietUntilExplicitRetry() async {
  var attempts = 0
  let state = WebLoginState(
    service: .quark, options: RuntimeOptions(environment: [:]),
    validate: { _ in
      attempts += 1
      throw WebLoginExpiredFixture()
    }, finish: { _ in Issue.record("失效凭据不能完成登录") })
  state.retryValidation()
  #expect(attempts == 0)
  let credentials = WebLoginCredentials(cookie: "__pus=expired; __puus=expired")
  state.capture(credentials)
  while state.checking { await Task.yield() }
  #expect(attempts == 1)
  #expect(state.validationError == nil)
  state.capture(credentials)
  #expect(!state.checking)
  state.retryValidation()
  while state.checking { await Task.yield() }
  #expect(attempts == 2)
  #expect(state.validationError != nil)
  state.reload()
  #expect(state.validationError == nil)
  #expect(state.isLoading)
  #expect(state.progress == 0)
  #expect(state.reloadID == 1)
}

@MainActor @Test func webLoginProcessesLatestCredentialAfterPendingValidationFails() async {
  var gate: CheckedContinuation<Void, Never>?
  var attempts: [String] = []
  var completed: WebLoginCredentials?
  let state = WebLoginState(
    service: .xunlei, options: RuntimeOptions(environment: [:]),
    validate: { credentials in
      attempts.append(credentials.token ?? "")
      if attempts.count == 1 {
        await withCheckedContinuation { gate = $0 }
        throw WebLoginExpiredFixture()
      }
    }, finish: { completed = try? $0.get() })
  state.capture(WebLoginCredentials(token: "expired"))
  while gate == nil { await Task.yield() }
  state.capture(WebLoginCredentials(token: "superseded"))
  state.capture(WebLoginCredentials(token: "current"))
  gate?.resume()
  while state.checking { await Task.yield() }
  #expect(attempts == ["expired", "current"])
  #expect(completed?.token == "current")
  #expect(state.validationError == nil)
}

@MainActor @Test func webLoginCancellationSuppressesLateValidationSuccess() async {
  var gate: CheckedContinuation<Void, Never>?
  var completed = false
  let state = WebLoginState(
    service: .xunlei, options: RuntimeOptions(environment: [:]),
    validate: { _ in await withCheckedContinuation { gate = $0 } },
    finish: { _ in completed = true })
  state.capture(WebLoginCredentials(token: "local"))
  while gate == nil { await Task.yield() }
  state.stop()
  gate?.resume()
  while state.checking { await Task.yield() }
  #expect(!completed)
  state.capture(WebLoginCredentials(token: "late"))
  #expect(!state.checking)
}

@MainActor @Test func webLoginNonLoginFailureIsVisibleAndDemoActionsCannotAffectLiveState() async {
  let state = WebLoginState(
    service: .tianyi, options: RuntimeOptions(environment: [:]),
    validate: { _ in throw URLError(.notConnectedToInternet) },
    finish: { _ in Issue.record("网络失败不能完成登录") })
  state.demonstrateFailure()
  state.demonstrateSuccess()
  #expect(state.loadError == nil)
  #expect(!state.checking)
  state.capture(WebLoginCredentials(cookie: "local=1"))
  while state.checking { await Task.yield() }
  #expect(state.validationError != nil)
}

@MainActor @Test(arguments: [WebLoginService.mobile, .tianyi])
func webLoginDemoCredentialsRemainLocal(service: WebLoginService) async {
  var result: WebLoginCredentials?
  let state = WebLoginState(
    service: service,
    options: RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": "web-loading"]),
    demoWait: {}, validate: { _ in Issue.record("演示不得进入真实验证") },
    finish: { result = try? $0.get() })
  #expect(state.isLoading)
  #expect(state.progress == 0.36)
  state.demonstrateFailure()
  #expect(!state.isLoading)
  #expect(state.loadError != nil)
  state.reload()
  state.demonstrateSuccess()
  while state.checking { await Task.yield() }
  if service == .mobile {
    #expect(result?.phone == "13800000000")
    #expect(result?.token == "demo-local-only")
    #expect(result?.userDomainID == "demo-space")
  } else {
    #expect(result?.cookie == "demo_local=1")
  }
  #expect(state.reloadID == 0)
}
