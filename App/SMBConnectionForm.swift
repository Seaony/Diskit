import Core
import SwiftUI

struct SMBConnectionForm: View {
  private enum ShareChoice: Hashable {
    case value(String)
    case manual
  }
  @Bindable var editor: ConnectionEditorModel
  private var canList: Bool {
    !editor.busy && !(editor.draft.params["host"] ?? "").isEmpty
      && (editor.guestLogin || !(editor.draft.params["username"] ?? "").isEmpty)
  }
  var body: some View {
    EditorTextRow(
      editor: editor, key: "host", title: L("主机地址"), placeholder: L("192.168.1.10 或 DESKTOP-PC")
    )
    .onChange(of: editor.draft.params["host"]) { editor.shares = [] }
    Picker(L("登录方式"), selection: $editor.guestLogin) {
      Text(L("注册用户")).tag(false)
      Text(L("访客")).tag(true)
    }.pickerStyle(.segmented)
    if !editor.guestLogin {
      EditorTextRow(editor: editor, key: "username", title: L("用户名"), placeholder: L("账户名或邮箱"))
        .onChange(of: editor.draft.params["username"]) { editor.shares = [] }
      EditorPasswordRow(editor: editor, title: L("密码"))
    }
    if editor.shares.isEmpty {
      EditorTextRow(editor: editor, key: "share", title: L("共享名"), placeholder: L("共享文件夹名称"))
    } else {
      Picker(
        L("共享名"),
        selection: Binding(
          get: { ShareChoice.value(editor.draft.params["share"] ?? "") },
          set: { value in
            switch value {
            case .value(let name): editor.draft.params["share"] = name
            case .manual: editor.shares = []
            }
          })
      ) {
        Text(L("选择共享")).tag(ShareChoice.value(""))
        if let share = editor.draft.params["share"], !share.isEmpty, !editor.shares.contains(share)
        {
          Text(LF("手动填写的共享：%@", share)).tag(ShareChoice.value(share))
        }
        ForEach(editor.shares, id: \.self) { Text($0).tag(ShareChoice.value($0)) }
        Text(L("手动输入…")).tag(ShareChoice.manual)
      }
    }
    HStack {
      Spacer()
      Button(L("列出共享")) { editor.listShares() }.disabled(!canList)
        .help(canList ? L("读取主机上的共享文件夹") : L("请先填写主机地址，并选择访客或填写用户名"))
    }
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .smb, state: .blank) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .smb, state: .blank) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .smb, state: .filled) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .smb, state: .filled) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .smb, state: .error) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .smb, state: .error) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .smb, state: .testing) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .smb, state: .testing) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .smb, state: .success) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .smb, state: .success) { SMBConnectionForm(editor: $0) }.preferredColorScheme(
    .dark)
}
