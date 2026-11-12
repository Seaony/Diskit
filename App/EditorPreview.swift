import Core
import SwiftUI

struct EditorPreview<Content: View>: View {
  @State private var editor: ConnectionEditorModel
  private let inForm: Bool
  private let content: (ConnectionEditorModel) -> Content

  init(
    kind: ConnectionKind = .smb, state: DemoEditorState = .blank, inForm: Bool = true,
    search: String = "", @ViewBuilder content: @escaping (ConnectionEditorModel) -> Content
  ) {
    let options = RuntimeOptions(environment: [
      "DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": state == .blank ? "empty" : "mixed",
    ])
    let model = ConnectionEditorModel(model: AppModel(options: options))
    model.applyDemoFixture(kind: kind, state: state)
    model.search = search
    _editor = State(initialValue: model)
    self.inForm = inForm
    self.content = content
  }
  var body: some View {
    VStack(spacing: 0) {
      if inForm { Form { content(editor) }.formStyle(.grouped) } else { content(editor) }
      if let error = editor.visibleError {
        Text(error).foregroundStyle(DiskitTheme.error).padding(Space.lg)
      }
      if editor.busy {
        HStack {
          ProgressView().nativeProgressAppearance()
          Text(editor.stage ?? L("正在测试连接…"))
        }.padding(Space.lg)
      }
      if editor.testSucceeded {
        Label(L("连接测试成功"), systemImage: "checkmark.circle.fill").padding(Space.lg)
      }
    }.frame(width: 640, height: 640).background(DiskitTheme.background).tint(DiskitTheme.accent)
  }
}

#Preview("独立表单容器 · 浅色空态") {
  EditorPreview { SMBConnectionForm(editor: $0) }.preferredColorScheme(.light)
}
#Preview("独立表单容器 · 深色空态") {
  EditorPreview { SMBConnectionForm(editor: $0) }.preferredColorScheme(.dark)
}
