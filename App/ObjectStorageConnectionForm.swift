import Core
import SwiftUI

struct ObjectStorageConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    EditorTextRow(
      editor: editor, key: "endpoint", title: L("服务地址"), placeholder: "https://s3.example.com")
    EditorTextRow(editor: editor, key: "region", title: L("区域"), placeholder: "us-east-1")
    EditorTextRow(editor: editor, key: "bucket", title: L("存储桶"), placeholder: L("存储桶名称"))
    EditorTextRow(editor: editor, key: "accessKey", title: L("访问密钥"), placeholder: "Access Key ID")
    EditorPasswordRow(editor: editor, title: L("私密密钥"), placeholder: "Secret Access Key")
    Toggle(
      L("使用路径形式访问存储桶"),
      isOn: Binding(
        get: { editor.draft.params["pathStyle"] == "true" },
        set: { editor.draft.params["pathStyle"] = $0 ? "true" : "false" })
    )
    .help(L("MinIO 等自建服务通常需要路径形式；其他服务请按提供商设置选择"))
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .s3, state: .blank) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .s3, state: .blank) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .s3, state: .filled) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .s3, state: .filled) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .s3, state: .error) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .s3, state: .error) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .s3, state: .testing) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .s3, state: .testing) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .s3, state: .success) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .s3, state: .success) { ObjectStorageConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}
