import AppKit
import Core
import Foundation
import Testing

private func editorJSON(_ value: [String: Any]) throws -> HTTPResponse {
  HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value))
}

@MainActor @Test func editorQuarkAndUCVerifyCookiesThenReuseSavedSession() async throws {
  let http = EditorLoginHTTP { request in
    if request.url?.path == "/account/info" {
      return try editorJSON([
        "success": true, "data": ["nickname": "Local cloud", "uid": "local-user"],
      ])
    }
    return try editorJSON([
      "status": 200, "code": 0, "data": ["total_capacity": 1000, "use_capacity": 200],
    ])
  }
  let app = editorProductionApp(transport: http)
  let web = EditorLoginWeb(WebLoginCredentials(cookie: "__pus=local; __puus=local"))
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  for kind in [ConnectionKind.quark, .ucDrive] {
    editor.choose(kind)
    editor.login()
    await editor.saving?.value
    #expect(editor.error == nil)
    #expect(editor.hasRequiredLogin)
    #expect(editor.draft.params["nickname"] == "Local cloud")
    #expect(editor.accountSpace?.used == 200)
    editor.startSave(loginOnly: true)
    await editor.saving?.value
    #expect(editor.error == nil)
  }
}

@MainActor @Test func editorPikPakVerifiesPasswordAndReusesTokenWithoutRetainingPasswordInParams()
  async throws
{
  let http = EditorLoginHTTP { request in
    switch request.url?.path {
    case "/v1/shield/captcha/init":
      return try editorJSON(["captcha_token": "local-captcha", "expires_in": 300])
    case "/v1/auth/signin", "/v1/auth/token":
      return try editorJSON([
        "access_token": "local-access", "refresh_token": "local-refresh", "expires_in": 7200,
        "sub": "local-user",
      ])
    case "/v1/user/me":
      return try editorJSON([
        "sub": "local-user", "name": "PikPak fixture", "email": "local@example.invalid",
      ])
    case "/drive/v1/about": return try editorJSON(["quota": ["limit": "1000", "usage": "400"]])
    default: throw URLError(.unsupportedURL)
    }
  }
  let app = editorProductionApp(transport: http)
  let editor = ConnectionEditorModel(model: app)
  editor.choose(.pikPak)
  editor.draft.params["username"] = "local@example.invalid"
  editor.password = "local-password"
  editor.login()
  await editor.saving?.value
  #expect(editor.error == nil)
  #expect(editor.draft.params["nickname"] == "PikPak fixture")
  #expect(editor.accountSpace?.used == 400)
  #expect(editor.draft.params["password"] == nil)
  editor.startSave(loginOnly: true)
  await editor.saving?.value
  #expect(editor.error == nil)
}

@MainActor @Test func editorWebMissingCredentialsNeverReachTransport() async throws {
  let http = EditorLoginHTTP { _ in throw URLError(.unsupportedURL) }
  let app = editorProductionApp(transport: http)
  for service in WebLoginService.allCases {
    let editor = ConnectionEditorModel(
      model: app, webFactory: { EditorLoginWeb(WebLoginCredentials()) })
    await #expect(throws: ConnectionError.authentication) { try await editor.loginWeb(service) }
    #expect(editor.webLogin == nil)
    #expect(!editor.didSave)
  }
  #expect(await http.requests.isEmpty)
}

@MainActor @Test func editorManualLoginRejectsInvalidCredentialsBeforeNetwork() async throws {
  let http = EditorLoginHTTP { _ in throw URLError(.unsupportedURL) }
  let app = editorProductionApp(transport: http)
  let editor = ConnectionEditorModel(model: app)
  editor.manualLogin = true
  editor.password = ""
  await #expect(throws: ConnectionError.invalidFields) { try await editor.loginWeb(.quark) }
  #expect(await http.requests.isEmpty)
  editor.manualLogin = false
  await #expect(throws: ConnectionError.notImplemented) { try await editor.loginWeb(.quark) }
}

@MainActor @Test func editorWebTransportFailuresDisconnectWithoutPromotingCredentials() async throws
{
  let http = EditorLoginHTTP { _ in throw URLError(.notConnectedToInternet) }
  let app = editorProductionApp(transport: http)
  let values: [(WebLoginService, WebLoginCredentials)] = [
    (.mobile, WebLoginCredentials(phone: "13800000000", token: "local-token")),
    (.xunlei, WebLoginCredentials(token: "local-token")),
    (.lanzou, WebLoginCredentials(cookie: "phpdisk_info=local; phpdisk_zinfo=local")),
  ]
  for (service, credentials) in values {
    let editor = ConnectionEditorModel(model: app, webFactory: { EditorLoginWeb(credentials) })
    do {
      try await editor.loginWeb(service)
      Issue.record("网络失败不能完成登录")
    } catch {}
    #expect(editor.draft.params["accountReady"] == nil)
    #expect(editor.password.isEmpty)
    #expect(editor.webLogin == nil)
  }
}

@MainActor @Test func editorMobileXunleiAndLanzouValidateBeforeAcceptingSecret() async throws {
  let http = EditorLoginHTTP { request in
    let path = request.url?.path ?? ""
    if path.contains("qryRoutePolicy") {
      return try editorJSON([
        "success": true, "code": "0000",
        "data": [
          "routePolicyList": [
            [
              "modName": "personal", "httpsUrl": "https://personal.yun.139.com",
              "hashName": "sha256",
            ]
          ]
        ],
      ])
    }
    if path.contains("getPersonalDiskInfo") {
      return try editorJSON([
        "success": true, "code": "0000", "data": ["diskSize": 1000, "freeDiskSize": 600],
      ])
    }
    if path.contains("about") { return try editorJSON(["quota": ["limit": 1000, "usage": 400]]) }
    if path.contains("mydisk.php") {
      return HTTPResponse(
        status: 200, body: Data("<script>var uid='local-user'; var vei='local-vei';</script>".utf8))
    }
    throw URLError(.unsupportedURL)
  }
  let app = editorProductionApp(transport: http)
  let values: [(ConnectionKind, WebLoginService, WebLoginCredentials)] = [
    (
      .mobileCloud, .mobile,
      WebLoginCredentials(phone: "13800000000", token: "local-token", userDomainID: "local-domain")
    ),
    (.thunderDrive, .xunlei, WebLoginCredentials(token: "local-token")),
    (.lanzou, .lanzou, WebLoginCredentials(cookie: "phpdisk_info=local; phpdisk_zinfo=local")),
  ]
  for (kind, service, credentials) in values {
    let editor = ConnectionEditorModel(model: app, webFactory: { EditorLoginWeb(credentials) })
    editor.choose(kind)
    let requestCount = await http.requests.count
    try await editor.loginWeb(service)
    let paths = await http.requests.dropFirst(requestCount).compactMap { $0.url?.path }
    switch service {
    case .mobile:
      #expect(paths == ["/user/route/qryRoutePolicy", "/user/disk/getPersonalDiskInfo"])
    case .xunlei: #expect(paths.count == 2 && paths.allSatisfy { $0.hasSuffix("/about") })
    case .lanzou: #expect(paths == ["/mydisk.php"])
    default: Issue.record("此用例仅覆盖移动、迅雷与蓝奏")
    }
    #expect(editor.hasRequiredLogin)
    #expect(!editor.password.isEmpty)
    if kind == .mobileCloud {
      #expect(editor.draft.params["phone"] == "13800000000")
      #expect(editor.draft.params["userDomainID"] == "local-domain")
    }
  }
}

@MainActor @Test func editorTianyiFamilyLoginRequiresExplicitChoiceWhenSeveralFamiliesExist()
  async throws
{
  for familyCount in [1, 2] {
    let http = EditorLoginHTTP { request in
      let path = request.url?.path ?? ""
      if path.contains("unifyLoginForPC") {
        return HTTPResponse(
          status: 302, headers: ["Location": "https://cloud.189.cn/local-callback"])
      }
      if path == "/local-callback" { return HTTPResponse(status: 200, url: request.url) }
      if path.contains("getSessionForPC") {
        return try editorJSON([
          "res_code": 0, "accessToken": "local-access", "refreshToken": "local-refresh",
          "sessionKey": "local-session", "sessionSecret": "secret-0123456789",
          "familySessionKey": "local-family", "familySessionSecret": "family-secret-0123456",
          "loginName": "Local Tianyi",
        ])
      }
      if path.contains("getUserSizeInfo") {
        return try editorJSON([
          "account": "local-user", "cloudCapacityInfo": ["totalSize": 1000, "usedSize": 100],
          "familyCapacityInfo": ["totalSize": 2000, "usedSize": 300],
        ])
      }
      if path.contains("getFamilyList") {
        return try editorJSON([
          "familyInfoResp": (1...familyCount).map {
            ["familyId": "family-\($0)", "remarkName": "Family \($0)"]
          }
        ])
      }
      throw URLError(.unsupportedURL)
    }
    let app = editorProductionApp(transport: http)
    let editor = ConnectionEditorModel(
      model: app, webFactory: { EditorLoginWeb(WebLoginCredentials(cookie: "SSON=local")) })
    editor.choose(.tianyiDrive)
    editor.draft.params["scope"] = "family"
    editor.login()
    await editor.saving?.value
    #expect(editor.error == nil)
    #expect(editor.hasRequiredLogin)
    #expect(editor.tianyiFamilySpaces.count == familyCount)
    #expect(editor.draft.params["familyID"] == (familyCount == 1 ? "family-1" : nil))
    editor.save()
    await editor.saving?.value
    #expect(editor.didSave == (familyCount == 1))
    #expect((editor.error != nil) == (familyCount > 1))
  }
}
