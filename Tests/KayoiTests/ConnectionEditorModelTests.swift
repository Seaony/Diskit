import Core
import Foundation
import Testing

@MainActor @Test func editorDefersRequiredFieldErrorsUntilBlur() {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let editor = ConnectionEditorModel(model: model)
  editor.choose(.smb)
  #expect(editor.fieldError("host") == nil)
  editor.touchedFields.insert("host")
  #expect(editor.fieldError("host") != nil)
  #expect(!editor.canSave)
}

@MainActor @Test func discoveredDraftIsAdditionAndCanReturnToTypes() {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  model.editing = Connection()
  let editor = ConnectionEditorModel(model: model)
  editor.load()
  #expect(editor.chosen)
  #expect(!editor.isEditing)
  editor.showTypes()
  #expect(!editor.chosen)
}

@MainActor @Test func demoWebLoginCompletesWithoutNetworkAuthorizer() async throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let editor = ConnectionEditorModel(model: model)
  editor.choose(.mobileCloud)
  #expect(!editor.hasRequiredLogin)
  try await editor.loginWeb(.mobile)
  #expect(editor.hasRequiredLogin)
  #expect(editor.password == "demo-local-only")
  #expect(editor.accountSpace?.total == 256_000_000_000)
  editor.busy = true
  #expect(!editor.canSave)
}

@Test func typeSearchSupportsInitialsAndMergesWebDAV() {
  #expect(ConnectionTypeCatalog.matching("tyyp").flatMap(\.kinds).contains(.tianyiDrive))
  let kinds = ConnectionTypeCatalog.matching("webdav").flatMap(\.kinds)
  #expect(kinds == [.webdavHTTPS])
}

@Test func pairingDigitsRejectsNonASCIIAndLimitsPaste() {
  #expect(PairingDigits.normalized("１２3a456789") == "345678")
  #expect(
    PairingDigits.replacing("1234567", at: 0, in: Array(repeating: "", count: 6)).joined()
      == "123456")
}

@Test func editorRejectsUneditedWebDAVTemplate() {
  var draft = Connection()
  draft.kind = .webdavHTTPS
  draft.params["url"] = "https://nas.local/remote.php/dav/files/USERNAME/"
  #expect(EditorValidation.addressIssue(draft) != nil)
  draft.params["url"] = "https://nas.local/dav"
  #expect(EditorValidation.addressIssue(draft) == nil)
}

@MainActor @Test func changingTypeDoesNotReuseAnotherServicesLogin() {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let editor = ConnectionEditorModel(model: model)
  editor.choose(.mobileCloud)
  editor.completeDemoLogin()
  editor.choose(.thunderDrive)
  #expect(!editor.hasRequiredLogin)
  #expect(editor.password.isEmpty)
  #expect(editor.draft.params["phone"] == nil)
}

@MainActor @Test func editingAnExistingShareRemainsEditing() async throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let existing = try #require(model.connections.connections.first)
  model.editing = existing
  let editor = ConnectionEditorModel(model: model)
  editor.load()
  #expect(editor.isEditing)
}
