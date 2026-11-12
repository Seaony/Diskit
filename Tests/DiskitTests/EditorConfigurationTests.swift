import Core
import Foundation
import Testing

@MainActor @Test func editorSelectionAndDefaultsPreserveUserNamesAndCustomEndpoints() {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"])))
  editor.search = "webdav"
  editor.chooseSelected()
  #expect(editor.draft.kind == .webdavHTTPS)
  editor.draft.name = "My storage"
  editor.choose(.s3)
  #expect(editor.draft.name == "My storage")
  #expect(editor.draft.params["region"] == "us-east-1")
  #expect(editor.draft.params["pathStyle"] == "false")
  editor.draft.params["endpoint"] = "https://private.invalid"
  editor.applyObjectStorageDefaults(for: .s3, previousKind: .s3)
  #expect(editor.draft.params["endpoint"] == "https://private.invalid")
  editor.choose(.cloudflareR2)
  #expect(editor.draft.params["endpoint"] == "")
  #expect(editor.draft.params["region"] == "auto")
  editor.choose(.lanzou)
  #expect(editor.draft.params["authMode"] == "account")
  editor.choose(.tianyiDrive)
  #expect(editor.draft.params["scope"] == "personal")
  editor.choose(.androidWiFi)
  editor.showTypes()
  #expect(editor.selectedKind == .androidUSB)
  #expect(!editor.chosen)
  editor.search = "no-such-kind"
  editor.selectedKind = nil
  editor.chooseSelected()
  #expect(!editor.chosen)
  editor.search = ""
  editor.moveSelection(1)
  #expect(editor.selectedKind == .androidUSB)
}

@MainActor @Test func editorDeviceSelectionPreservesExplicitNamesAndClearsOldIdentity() {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let editor = ConnectionEditorModel(model: app)
  for kind in [ConnectionKind.androidUSB, .ricohGR, .cameraUSB] {
    editor.choose(kind)
    editor.draft.params = [:]
    editor.draft.name = kind.defaultName
    editor.autoSelectDevice()
    let id = editor.selectedDeviceID
    #expect(!id.isEmpty)
    #expect(editor.draft.name != kind.defaultName)
    editor.draft.name = "Custom name"
    editor.draft.params["usbLocationID"] = "stale-location"
    editor.selectDevice(id)
    #expect(editor.draft.name == "Custom name")
    #expect(editor.draft.params["usbLocationID"] == nil)
    editor.autoSelectDevice()
    #expect(editor.selectedDeviceID == id)
    editor.draft.params = [
      "serial": kind == .androidUSB ? "demo-usb" : kind == .ricohGR ? "demo-gr" : "demo-camera"
    ]
    #expect(editor.selectedDeviceID == id)
    editor.selectDevice("missing-device")
    #expect(editor.selectedDeviceID.isEmpty)
    #expect(editor.draft.params["serial"] == nil)
  }
  editor.choose(.smb)
  editor.selectDevice("unknown")
  #expect(editor.selectedDeviceID.isEmpty)
}

@MainActor @Test func editorLoadRunsOnceAndRetainsSavedCredentialsAndGuestMode() throws {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  var draft = Connection()
  draft.kind = .smb
  draft.name = "Guest"
  draft.params = ["guest": "true", "host": "demo.invalid", "share": "Photos"]
  try app.secrets.write(Data("private-fixture".utf8), for: draft.passwordKey)
  app.editing = draft
  let editor = ConnectionEditorModel(model: app)
  editor.load()
  #expect(editor.password == "private-fixture")
  #expect(editor.guestLogin)
  #expect(editor.chosen)
  editor.draft.name = "Unsaved change"
  editor.load()
  #expect(editor.draft.name == "Unsaved change")
  #expect(editor.canSave)
}

@MainActor @Test func editorValidationReportsMissingFieldsAndAddressOnlyAfterTouch() {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"])))
  editor.choose(.quark)
  #expect(editor.missingFieldsDescription == L("请先登录账号"))
  editor.choose(.webdavHTTPS)
  #expect(editor.missingFieldsDescription != nil)
  let field = editor.parameter("url")
  #expect(field.wrappedValue.isEmpty)
  field.wrappedValue = "bad url"
  #expect(editor.fieldError("url") == nil)
  editor.touchedFields.insert("url")
  #expect(editor.fieldError("url") == EditorValidation.addressIssue(editor.draft))
  #expect(editor.missingFieldsDescription == EditorValidation.addressIssue(editor.draft))
  field.wrappedValue = "https://demo.invalid/dav"
  #expect(editor.fieldError("url") == nil)
  #expect(editor.missingFieldsDescription == nil)
  #expect(editor.canSave)
  editor.busy = true
  #expect(!editor.canSave)
}

@MainActor @Test func switchingAccountClearsVisibleIdentityAndUnsavedSecret() {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"])))
  editor.choose(.mobileCloud)
  editor.completeDemoLogin()
  editor.draft.params["avatarURL"] = "https://demo.invalid/avatar"
  editor.touchedFields = ["password"]
  editor.resetManualLogin()
  #expect(editor.model.forceLogin)
  #expect(!editor.hasRequiredLogin)
  #expect(editor.draft.params["nickname"] == nil)
  #expect(editor.draft.params["avatarURL"] == nil)
  #expect(editor.accountSpace == nil)
  #expect(editor.password.isEmpty)
  #expect(editor.touchedFields.isEmpty)
}

@MainActor @Test func sharePasswordRemovalOnlyAppliesToLanzouShareMode() {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"])))
  editor.choose(.lanzou)
  #expect(!editor.clearsSharePassword)
  #expect(editor.webService == .lanzou)
  editor.draft.params["authMode"] = "share"
  #expect(editor.clearsSharePassword)
  #expect(editor.webService == nil)
  #expect(!editor.requiresLogin)
  editor.password = "new-password"
  #expect(!editor.clearsSharePassword)
}

@MainActor @Test func demoPermissionActionsNeverOpenSystemSettings() {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"])))
  for kind in ConnectionKind.allCases {
    editor.choose(kind)
    #expect(editor.permissionSettingsURL == nil)
    #expect(editor.visibleError == nil)
    editor.openPermissionSettings()
    editor.error = "fixture"
    #expect(editor.visibleError == "fixture")
  }
}

@MainActor @Test(arguments: [ConnectionKind.s3, .minIO])
func objectStorageEditorMatchesBackendLocalHTTPPolicy(kind: ConnectionKind) {
  var draft = Connection(kind: kind, name: "local")
  for endpoint in [
    "http://nas.local:9000", "http://192.168.1.2:9000", "https://storage.example.com",
  ] {
    draft.params["endpoint"] = endpoint
    #expect(EditorValidation.addressIssue(draft) == nil)
  }
  for endpoint in ["http://storage.example.com", "http://8.8.8.8", "https://user:pass@nas.local"] {
    draft.params["endpoint"] = endpoint
    #expect(EditorValidation.addressIssue(draft) != nil)
  }
}
