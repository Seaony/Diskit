import Core
import SwiftUI

struct EditorPasswordRow: View {
  @Bindable var editor: ConnectionEditorModel
  let title: String
  var placeholder = ""
  @FocusState private var focused: Bool
  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .leading, spacing: Space.xs) {
        // 显示密码的小眼睛放在输入框里面靠右
        HStack(spacing: Space.xs) {
          Group {
            if editor.passwordVisible {
              TextField(placeholder.isEmpty ? title : placeholder, text: $editor.password)
            } else {
              SecureField(placeholder.isEmpty ? title : placeholder, text: $editor.password)
            }
          }
          .labelsHidden().focused($focused).accessibilityLabel(title)
          Button {
            editor.passwordVisible.toggle()
          } label: {
            Image(systemName: editor.passwordVisible ? "eye.slash" : "eye")
              .foregroundStyle(KayoiTheme.secondaryText)
          }.buttonStyle(.plain).pointerStyle(.link)
            .help(editor.passwordVisible ? L("隐藏密码") : L("显示密码"))
            .accessibilityLabel(editor.passwordVisible ? L("隐藏密码") : L("显示密码"))
        }
        .kayoiField(focused: focused)
        if let error = editor.fieldError("password") {
          Text(error).font(.caption).foregroundStyle(KayoiTheme.error)
        }
      }
      .onChange(of: focused) { was, now in
        if was && !now { editor.touchedFields.insert("password") }
      }
    }
  }
}

#Preview("light · 空白") {
  EditorPreview { EditorPasswordRow(editor: $0, title: L("密码")) }.preferredColorScheme(.light)
}

#Preview("dark · 空白") {
  EditorPreview { EditorPasswordRow(editor: $0, title: L("密码")) }.preferredColorScheme(.dark)
}
