import Core
import Testing

@Test func editorReusedWindowChangesFromSavedLocationToDiscoveredDevice() {
  var title = EditorWindowTitle.text(name: "Demo quark", isSaved: true)
  EditorWindowTitle.synchronize(
    EditorWindowTitle.text(name: "Pixel 8", isSaved: false), current: title
  ) { title = $0 }
  #expect(title == L("添加位置"))
}

@Test func editorWindowTitleTracksRenamingWithoutRedundantHostUpdates() {
  var title = EditorWindowTitle.text(name: "Original", isSaved: true)
  var updates = 0
  let next = EditorWindowTitle.text(name: "Renamed", isSaved: true)
  EditorWindowTitle.synchronize(next, current: title) {
    title = $0
    updates += 1
  }
  EditorWindowTitle.synchronize(next, current: title) {
    title = $0
    updates += 1
  }
  #expect(title == LF("编辑“%@”", "Renamed"))
  #expect(updates == 1)
}
