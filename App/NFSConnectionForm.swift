import Core
import SwiftUI

struct NFSConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    EditorTextRow(editor: editor, key: "host", title: L("服务器地址"), placeholder: "192.168.1.10")
    EditorTextRow(editor: editor, key: "path", title: L("导出路径"), placeholder: "/volume/share")
      .help(L("填写服务器共享出来的文件夹路径，例如 /volume/share。"))
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .nfs, state: .blank) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .nfs, state: .blank) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .nfs, state: .filled) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .nfs, state: .filled) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .nfs, state: .error) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .nfs, state: .error) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .nfs, state: .testing) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .nfs, state: .testing) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .nfs, state: .success) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .nfs, state: .success) { NFSConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}
