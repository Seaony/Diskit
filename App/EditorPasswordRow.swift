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
        HStack(spacing: Space.sm) {
          Group {
            if editor.passwordVisible {
              TextField(placeholder.isEmpty ? title : placeholder, text: $editor.password)
            } else {
              SecureField(placeholder.isEmpty ? title : placeholder, text: $editor.password)
            }
          }
          .textFieldStyle(.plain).labelsHidden().focused($focused).accessibilityLabel(title)
          Button {
            editor.passwordVisible.toggle()
          } label: {
            Image(systemName: editor.passwordVisible ? "eye.slash" : "eye")
          }.buttonStyle(.plain)
            .help(editor.passwordVisible ? L("隐藏密码") : L("显示密码"))
            .accessibilityLabel(editor.passwordVisible ? L("隐藏密码") : L("显示密码"))
        }
        .padding(Space.sm)
        .background(
          KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(
            focused ? KayoiTheme.focus : KayoiTheme.border)
        }
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
