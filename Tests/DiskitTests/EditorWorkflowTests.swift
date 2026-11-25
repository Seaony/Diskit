import ADB
import AppKit
import Core
import Foundation
import Testing

private struct EditorExpiredLogin: LoginRequiredFailure {
  let requiresLogin = true
}

@MainActor private final class EditorWebAuthorizer: WebLoginAuthorizing {
  var calls: [WebLoginService] = []
  var cancellationCount = 0
  var failure: Error?
  var validates = false
  func authorize(
    service: WebLoginService, options: RuntimeOptions,
    validate: @escaping @MainActor (WebLoginCredentials) async throws -> Void
  ) async throws -> WebLoginCredentials {
    calls.append(service)
    if let failure { throw failure }
    let credentials = WebLoginCredentials(cookie: "local-fixture")
    if validates { try await validate(credentials) }
    return credentials
  }
  func cancel() { cancellationCount += 1 }
}

@MainActor private func workflowEditor() -> ConnectionEditorModel {
  let transport = EditorLoginHTTP { _ in throw URLError(.unsupportedURL) }
  let app = editorProductionApp(
    transport: transport, options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  return ConnectionEditorModel(model: app, demoWait: { try Task.checkCancellation() })
}

@MainActor @Test func editorSavingDemoRemotePersistsAndClearsProgress() async throws {
  let editor = workflowEditor()
  var tested: [UUID] = []
  editor.model.connections.testRemote = { connection in
    tested.append(connection.id)
    return SpaceInfo(total: 100, used: 20)
  }
  editor.choose(.quark)
  try await editor.loginWeb(.quark)
  editor.save()
  let task = try #require(editor.saving)
  #expect(editor.busy)
  editor.save()
  await task.value
  #expect(tested == [editor.draft.id])
  #expect(editor.didSave)
  #expect(!editor.busy)
  #expect(editor.saving == nil)
  #expect(editor.stage == nil)
  #expect(editor.error == nil)
  #expect(editor.model.connections.connections.contains { $0.id == editor.draft.id })
}

@MainActor @Test func editorFailedSaveStaysOpenAndDoesNotPersistDraft() async throws {
  let editor = workflowEditor()
  editor.choose(.smb)
  editor.draft.name = ""
  editor.save()
  await editor.saving?.value
  #expect(!editor.didSave)
  #expect(editor.error != nil)
  #expect(!editor.errorNeedsLogin)
  #expect(!editor.busy)
  #expect(!editor.model.connections.connections.contains { $0.id == editor.draft.id })
}

@MainActor @Test func cancellingBeforeSavePreventsPersistenceAndClearsAuthorization() async throws {
  let editor = workflowEditor()
  editor.choose(.mobileCloud)
  let web = EditorWebAuthorizer()
  editor.webLogin = web
  editor.model.forceLogin = true
  editor.save()
  let task = try #require(editor.saving)
  editor.cancelWork()
  await task.value
  #expect(web.cancellationCount == 1)
  #expect(editor.webLogin == nil)
  #expect(!editor.model.forceLogin)
  #expect(!editor.busy)
  #expect(editor.stage == nil)
  #expect(!editor.didSave)
  #expect(!editor.model.connections.connections.contains { $0.id == editor.draft.id })
}

@MainActor @Test func editorLoginOnlyUsesInjectedAuthorizerWithoutSavingLocation() async throws {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let web = EditorWebAuthorizer()
  web.validates = true
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  editor.choose(.ucDrive)
  let before = app.connections.connections
  editor.login()
  await editor.saving?.value
  #expect(web.calls == [.uc])
  #expect(editor.hasRequiredLogin)
  #expect(editor.lastActionWasLogin)
  #expect(!editor.didSave)
  #expect(editor.webLogin == nil)
  #expect(!app.forceLogin)
  #expect(app.connections.connections == before)
}

@MainActor @Test func editorLoginFailureSeparatesExpiredLoginFromNetworkFailure() async throws {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let web = EditorWebAuthorizer()
  let editor = ConnectionEditorModel(model: app, webFactory: { web })
  editor.choose(.tianyiDrive)
  web.failure = EditorExpiredLogin()
  editor.login()
  await editor.saving?.value
  #expect(editor.errorNeedsLogin)
  #expect(editor.error != nil)
  #expect(!editor.hasRequiredLogin)
  web.failure = URLError(.timedOut)
  editor.login()
  await editor.saving?.value
  #expect(!editor.errorNeedsLogin)
  #expect(editor.error != nil)
  #expect(editor.webLogin == nil)
  #expect(!editor.busy)
}

@MainActor @Test func editorSixDigitCodePairsOnceAndRejectsEarlySubmission() async throws {
  let editor = workflowEditor()
  editor.choose(.androidWiFi)
  editor.autoSelectDevice()
  editor.updatePairingCode("12a3")
  #expect(editor.pairingCode == "123")
  #expect(editor.pairingTask == nil)
  editor.updatePairingCode("1234567")
  let task = try #require(editor.pairingTask)
  #expect(editor.busy)
  editor.pairWirelessDevice()
  await task.value
  #expect(editor.draft.params["guid"] == "adb-demo-ABC123")
  #expect(editor.pairingCode.isEmpty)
  #expect(!editor.busy)
  #expect(editor.pairingTask == nil)
  #expect(editor.stage == nil)
}

@MainActor @Test func editorPairingCancelAndMissingDiscoveryNeverPersistIdentity() async throws {
  let editor = workflowEditor()
  editor.choose(.androidWiFi)
  editor.pairingID = "not-discovered"
  editor.pairWirelessDevice()
  #expect(editor.pairingTask == nil)
  editor.pairingID = ""
  editor.autoSelectDevice()
  editor.updatePairingCode("123456")
  let task = try #require(editor.pairingTask)
  editor.cancelWork()
  await task.value
  #expect(editor.draft.params["guid"] == nil)
  #expect(!editor.busy)
}

@MainActor @Test func editorListsDemoSharesAndSelectsFirstResult() async throws {
  let editor = workflowEditor()
  editor.choose(.smb)
  editor.guestLogin = true
  editor.draft.params["host"] = "demo.invalid"
  editor.listShares()
  await editor.shareTask?.value
  #expect(editor.shares == ["Demo", "Photos", "Documents"])
  #expect(editor.draft.params["share"] == "Demo")
  #expect(editor.shareTask == nil)
  #expect(editor.stage == nil)
  #expect(!editor.busy)
  #expect(editor.error == nil)
}

@MainActor @Test func editorCancelsShareEnumerationWithoutPublishingResults() async throws {
  let editor = workflowEditor()
  editor.choose(.smb)
  editor.listShares()
  let task = try #require(editor.shareTask)
  editor.cancelWork()
  await task.value
  #expect(editor.shares.isEmpty)
  #expect(editor.error == nil)
  #expect(!editor.busy)
}

@MainActor @Test func editorDemoDirectLoginCanFinishOrCancelWithoutBrowser() async throws {
  let editor = workflowEditor()
  editor.choose(.pikPak)
  editor.busy = true
  editor.login()
  #expect(editor.saving == nil)
  #expect(!editor.model.forceLogin)
  editor.busy = false
  editor.login()
  let first = try #require(editor.saving)
  editor.cancelWork()
  await first.value
  #expect(!editor.hasRequiredLogin)
  editor.login()
  await editor.saving?.value
  #expect(editor.hasRequiredLogin)
  #expect(editor.accountSpace != nil)
  #expect(!editor.didSave)
  #expect(!editor.model.forceLogin)
}

// 选“无线调试”后只发现一台等待配对的手机时直接选上，输完六位配对码就会配对
@MainActor @Test func editorWiFiSelectsTheOnlyPairingDeviceAndPairsWhenItAppears() async throws {
  let editor = workflowEditor()
  editor.choose(.androidUSB)
  editor.choose(.androidWiFi)
  let device = try #require(editor.model.wirelessDevices.first { $0.type == .pairing })
  #expect(editor.pairingID == device.id)
  // 之前选的配对服务已经不在了：换成现在唯一的那台
  editor.pairingID = "gone"
  editor.pairingCode = "123456"
  editor.wirelessDevicesChanged()
  #expect(editor.pairingID == device.id)
  let task = try #require(editor.pairingTask)
  await task.value
  #expect(editor.draft.params["guid"] == "adb-demo-ABC123")
}
