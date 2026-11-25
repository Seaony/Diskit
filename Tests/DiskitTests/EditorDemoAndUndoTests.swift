import AppKit
import Core
import Testing

@Test func editorDemoSwitchesAreIgnoredOutsideDemo() {
  let options = RuntimeOptions(environment: [
    "DISKIT_DEMO_EDITOR_TYPE": "quark", "DISKIT_DEMO_EDITOR_STATE": "testing",
    "DISKIT_DEMO_WEB_SERVICE": "mobile",
  ])
  #expect(options.demoEditorKind == nil)
  #expect(options.demoEditorState == nil)
  #expect(options.demoWebService == nil)
}

@Test func editorDemoRuntimeSupportsEveryTypeAndStableState() {
  for kind in ConnectionKind.allCases {
    for state in DemoEditorState.allCases {
      let options = RuntimeOptions(environment: [
        "DISKIT_DEMO": "1", "DISKIT_DEMO_EDITOR_TYPE": kind.rawValue,
        "DISKIT_DEMO_EDITOR_STATE": state.rawValue,
      ])
      #expect(options.demoEditorKind == kind)
      #expect(options.demoEditorState == state)
    }
  }
}

@MainActor @Test func editorDemoFixturesNeverStartOperationsOrSave() {
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let original = app.connections.connections
  let editor = ConnectionEditorModel(model: app)
  for kind in ConnectionKind.allCases {
    for state in DemoEditorState.allCases {
      editor.applyDemoFixture(kind: kind, state: state)
      #expect(editor.draft.kind == kind)
      #expect(editor.busy == (state == .testing))
      #expect(editor.testSucceeded == (state == .success))
      #expect(!editor.didSave)
      #expect(editor.saving == nil)
      #expect(editor.pairingTask == nil)
      #expect(editor.shareTask == nil)
      #expect(editor.webLogin == nil)
    }
  }
  #expect(app.connections.connections == original)
}

@MainActor @Test func savedPresentationSupportsUndoAndRedoWithoutRestoringConnectionFields() throws
{
  let app = AppModel(options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]))
  let original = try #require(app.connections.connections.first)
  var edited = original
  edited.name = "Renamed"
  edited.color = "orange"
  try app.connections.setPresentation(id: original.id, name: edited.name, color: edited.color)
  let undo = app.undoManager
  undo.groupsByEvent = false
  undo.beginUndoGrouping()
  ConnectionPresentationUndo.register(
    previous: original, current: edited, manager: app.connections, undo: undo)
  undo.endUndoGrouping()
  undo.undo()
  let restored = try #require(app.connections.connections.first { $0.id == original.id })
  #expect(restored.name == original.name)
  #expect(restored.color == original.color)
  #expect(restored.params == original.params)
  undo.redo()
  let redone = try #require(app.connections.connections.first { $0.id == original.id })
  #expect(redone.name == edited.name)
  #expect(redone.color == edited.color)
  #expect(redone.params == original.params)
}
