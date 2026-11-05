import Core
import SwiftUI

struct EditorTextRow: View {
  @Bindable var editor: ConnectionEditorModel
  let key: String
  let title: String
  let placeholder: String
  @FocusState private var focused: Bool
  private var value: Binding<String> { key == "name" ? $editor.draft.name : editor.parameter(key) }
  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .leading, spacing: Space.xs) {
        TextField(placeholder, text: value).labelsHidden()
          .focused($focused).accessibilityLabel(title)
          .kayoiField(focused: focused)
          .onChange(of: focused) { was, now in if was && !now { editor.touchedFields.insert(key) } }
        if let error = editor.fieldError(key) {
          Text(error).font(.caption).foregroundStyle(KayoiTheme.error)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview("light · 空白") {
  EditorPreview {
    EditorTextRow(editor: $0, key: "host", title: L("主机地址"), placeholder: "demo.invalid")
  }.preferredColorScheme(.light)
}

#Preview("dark · 空白") {
  EditorPreview {
    EditorTextRow(editor: $0, key: "host", title: L("主机地址"), placeholder: "demo.invalid")
  }.preferredColorScheme(.dark)
}
