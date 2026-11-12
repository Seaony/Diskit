import AppKit
import Core
import CoreTestSupport
import Testing

@MainActor @Test func demoControlCommandsAreIgnoredInLiveMode() async {
  let app = editorProductionApp(transport: EditorLoginHTTP { _ in throw RemoteError.unsupported })
  let editor = ConnectionEditorModel(model: app)
  editor.busy = true
  var applied: [NSAppearance.Name] = []
  app.selectDemoEditorState(.success)
  app.selectDemoAppearance("dark") { applied.append($0) }
  #expect(app.demoEditorStateOverride == nil)
  #expect(app.demoEditorRevision == 0)
  #expect(app.demoAppearanceOverride == nil)
  #expect(applied.isEmpty)
  await editor.applyRequestedDemoState()
  #expect(editor.busy)
  #expect(!editor.testSucceeded)
}

@MainActor @Test func demoControlStateIsUsedByNewAndExistingEditors() async {
  let app = AppModel(
    options: RuntimeOptions(environment: [
      "DISKIT_DEMO": "1", "DISKIT_DEMO_EDITOR_TYPE": "smb", "DISKIT_DEMO_EDITOR_STATE": "blank",
    ]))
  app.selectDemoEditorState(.filled)
  let editor = ConnectionEditorModel(model: app)
  editor.load()
  #expect(editor.draft.kind == .smb)
  #expect(editor.draft.params["host"] == "demo.invalid")
  editor.draft.kind = .nfs
  editor.passwordVisible = true
  editor.manualLogin = true
  editor.guestLogin = true
  editor.error = "old error"
  app.selectDemoEditorState(.success)
  await editor.applyRequestedDemoState()
  #expect(editor.draft.kind == .nfs)
  #expect(editor.testSucceeded)
  #expect(!editor.didSave)
  #expect(editor.error == nil)
  #expect(!editor.passwordVisible)
  #expect(!editor.manualLogin)
  #expect(!editor.guestLogin)
  #expect(app.demoEditorRevision == 2)
}

@MainActor @Test func demoControlWaitsForCancellationBeforePublishingStableFixture() async throws {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let editor = ConnectionEditorModel(model: app)
  editor.choose(.quark)
  let started = TestEvent()
  let pending = TestEvent()
  var finished = false
  editor.saving = Task { @MainActor in
    defer {
      finished = true
      editor.busy = false
      editor.stage = nil
    }
    started.signal()
    do { try await pending.wait() } catch is CancellationError {} catch { Issue.record(error) }
  }
  try await started.wait()
  app.selectDemoEditorState(.testing)
  await editor.applyRequestedDemoState()
  #expect(finished)
  #expect(editor.busy)
  #expect(editor.stage != nil)
  #expect(editor.saving == nil)
  #expect(editor.pairingTask == nil)
  #expect(editor.shareTask == nil)
  #expect(!editor.didSave)
  #expect(!app.connections.connections.contains { $0.id == editor.draft.id })
  app.selectDemoEditorState(.blank)
  await editor.applyRequestedDemoState()
  #expect(!editor.busy)
  #expect(editor.stage == nil)
  #expect(editor.password.isEmpty)
  #expect(editor.draft.params["accountReady"] == nil)
}

@MainActor @Test func demoAppearanceCommandsOnlyApplySupportedProcessAppearances() {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  var applied: [NSAppearance.Name] = []
  app.selectDemoAppearance("dark") { applied.append($0) }
  app.selectDemoAppearance("light") { applied.append($0) }
  app.selectDemoAppearance("unsupported") { applied.append($0) }
  #expect(applied == [.darkAqua, .aqua])
  #expect(app.demoAppearanceOverride == "light")
}
