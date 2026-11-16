import Core
import Foundation
import Testing

private func quarkHTTP() -> EditorLoginHTTP {
  EditorLoginHTTP { request in
    let body: [String: Any] =
      request.url?.path == "/account/info"
      ? ["success": true, "data": ["nickname": "Local cloud", "uid": "local-user"]]
      : ["status": 200, "code": 0, "data": ["total_capacity": 1000, "use_capacity": 200]]
    return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: body))
  }
}

// 新位置登录后没保存就关窗口：钥匙串里不能留下这次登录的信息
@MainActor @Test func closingUnsavedEditorDeletesLoginSecrets() async throws {
  let app = editorProductionApp(transport: quarkHTTP())
  let web = EditorLoginWeb(WebLoginCredentials(cookie: "__pus=new; __puus=new"))
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  editor.choose(.quark)
  editor.login()
  await editor.saving?.value
  #expect(editor.error == nil)
  let key = editor.draft.id.uuidString + ".cookie"
  #expect(try app.secrets.read(key) != nil)
  await editor.close().value
  #expect(try app.secrets.read(key) == nil)
}

// 换了类型后，上一个类型登录留下的信息也删掉
@MainActor @Test func switchingKindDeletesUnsavedLoginSecrets() async throws {
  let app = editorProductionApp(transport: quarkHTTP())
  let web = EditorLoginWeb(WebLoginCredentials(cookie: "__pus=new; __puus=new"))
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  editor.choose(.quark)
  editor.login()
  await editor.saving?.value
  let key = editor.draft.id.uuidString + ".cookie"
  #expect(try app.secrets.read(key) != nil)
  editor.choose(.smb)
  #expect(try app.secrets.read(key) == nil)
}

// 已保存的位置换账号后没保存就关窗口：钥匙串恢复成原来的账号；保存了就留新账号
@MainActor @Test func closingEditorAfterSwitchingAccountRestoresSavedSecrets() async throws {
  let app = editorProductionApp(transport: quarkHTTP())
  let saved = Connection(kind: .quark, name: "Saved", openInFinderAfterMount: false)
  try await app.connections.save(saved, password: "")
  let key = saved.id.uuidString + ".cookie"
  let original = Data("original-cookie".utf8)
  try app.secrets.write(original, for: key)

  for keepsNewAccount in [false, true] {
    app.editing = saved
    let web = EditorLoginWeb(WebLoginCredentials(cookie: "__pus=new; __puus=new"))
    let editor = ConnectionEditorModel(model: app, webFactory: { web })
    editor.load()
    editor.resetManualLogin()
    editor.login()
    await editor.saving?.value
    #expect(editor.error == nil)
    let switched = try app.secrets.read(key)
    #expect(switched != nil && switched != original)
    if keepsNewAccount {
      editor.save()
      await editor.saving?.value
      #expect(editor.didSave)
      await editor.close().value
      #expect(try app.secrets.read(key) == switched)
    } else {
      await editor.close().value
      #expect(try app.secrets.read(key) == original)
      #expect(app.connections.connections.contains { $0.id == saved.id })
    }
  }
}

// 登录请求还在路上时先点“取消”再关窗口：迟到的登录结果不能盖掉恢复回去的原账号
private actor SlowQuarkHTTP: HTTPTransport {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var started = false
  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    started = true
    if !released { await withCheckedContinuation { waiters.append($0) } }
    let body: [String: Any] =
      request.url?.path == "/account/info"
      ? ["success": true, "data": ["nickname": "Late", "uid": "late-user"]]
      : ["status": 200, "code": 0, "data": ["total_capacity": 1000, "use_capacity": 200]]
    return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: body))
  }
}

@MainActor @Test func cancelThenCloseWaitsForTheLateLoginBeforeRestoring() async throws {
  let http = SlowQuarkHTTP()
  let app = editorProductionApp(transport: http)
  let saved = Connection(kind: .quark, name: "Saved", openInFinderAfterMount: false)
  try await app.connections.save(saved, password: "")
  let key = saved.id.uuidString + ".cookie"
  let original = Data("original-cookie".utf8)
  try app.secrets.write(original, for: key)
  app.editing = saved
  let web = EditorLoginWeb(WebLoginCredentials(cookie: "__pus=late; __puus=late"))
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  editor.load()
  editor.resetManualLogin()
  editor.login()
  while !(await http.started) { await Task.yield() }
  let login = try #require(editor.saving)
  editor.cancelWork()
  let closing = editor.close()
  await http.release()
  await closing.value
  await login.value
  #expect(try app.secrets.read(key) == original)
}
