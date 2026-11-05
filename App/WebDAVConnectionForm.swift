import Core
import SwiftUI

struct WebDAVConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    Picker(L("服务预设"), selection: $editor.webdavPreset) {
      ForEach(WebDAVPreset.all) { preset in Text(preset.title).tag(preset.id) }
    }.formRow(L("服务预设"))
    .onChange(of: editor.webdavPreset) { _, value in
      guard let preset = WebDAVPreset.all.first(where: { $0.id == value }), !preset.address.isEmpty
      else { return }
      editor.draft.kind = .webdavHTTPS
      editor.draft.params["url"] = preset.address
    }
    EditorTextRow(
      editor: editor, key: "url", title: L("服务器地址"), placeholder: "https://nas.local/dav/")
    Toggle(
      L("使用 HTTPS"),
      isOn: Binding(
        get: { editor.draft.kind == .webdavHTTPS },
        set: { secure in
          editor.draft.kind = secure ? .webdavHTTPS : .webdav
          if var address = URLComponents(string: editor.draft.params["url"] ?? ""),
            address.scheme != nil
          {
            address.scheme = secure ? "https" : "http"
            editor.draft.params["url"] = address.string
          }
        }))
    EditorTextRow(editor: editor, key: "username", title: L("用户名"), placeholder: L("账户名或邮箱"))
    EditorPasswordRow(editor: editor, title: L("密码"))
    if let preset = WebDAVPreset.all.first(where: { $0.id == editor.webdavPreset }) {
      Text(preset.instructions).font(.caption).foregroundStyle(KayoiTheme.secondaryText).fixedSize(
        horizontal: false, vertical: true)
    }
    if editor.draft.kind == .webdav {
      Label(L("HTTP 会以明文传输密码和文件，请只在可信网络中使用。"), systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(KayoiTheme.warning)
    }
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .webdavHTTPS, state: .blank) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .webdavHTTPS, state: .blank) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .webdavHTTPS, state: .filled) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .webdavHTTPS, state: .filled) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .webdavHTTPS, state: .error) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .webdavHTTPS, state: .error) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .webdavHTTPS, state: .testing) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .webdavHTTPS, state: .testing) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .webdavHTTPS, state: .success) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .webdavHTTPS, state: .success) { WebDAVConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}
