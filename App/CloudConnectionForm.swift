import Core
import SwiftUI

struct CloudConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  @State private var alternatives = false
  private var ready: Bool { editor.draft.params["accountReady"] == "true" }
  var body: some View {
    if editor.draft.kind.isExperimental {
      Label(L("这种连接方式未经服务商官方支持，可能随时失效。"), systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(KayoiTheme.warning)
    }
    if editor.draft.kind == .lanzou {
      Picker(L("访问方式"), selection: editor.parameter("authMode")) {
        Text(L("登录账号")).tag("account")
        Text(L("分享链接")).tag("share")
      }.pickerStyle(.segmented).fixedSize().formRow(L("访问方式"))
        .onChange(of: editor.draft.params["authMode"]) { editor.resetManualLogin() }
    }
    if editor.draft.kind == .lanzou && editor.draft.params["authMode"] == "share" {
      EditorTextRow(editor: editor, key: "shareURL", title: L("分享链接"), placeholder: "https://…")
      EditorPasswordRow(editor: editor, title: L("提取码"), placeholder: L("没有提取码时留空"))
      Text(L("分享链接以只读方式打开。清空提取码后保存，会删除之前保存的提取码。")).font(.caption).foregroundStyle(
        KayoiTheme.secondaryText)
    } else {
      if ready {
        HStack(spacing: Space.md) {
          Group {
            if !editor.model.options.isDemo, let raw = editor.draft.params["avatarURL"],
              let url = URL(string: raw), url.scheme == "https"
            {
              AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
              } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable()
              }
            } else {
              Image(systemName: "person.crop.circle.fill").resizable()
            }
          }.frame(width: 40, height: 40).clipShape(Circle()).foregroundStyle(
            KayoiTheme.secondaryText
          ).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(editor.draft.params["nickname"] ?? L("已登录")).font(.headline)
            if let space = editor.accountSpace {
              Text(EditorAccountSummary.text(space)).font(.caption).foregroundStyle(
                KayoiTheme.secondaryText)
            } else {
              Text(L("容量暂不可用")).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
            }
          }
          Spacer()
          Button(L("切换账号")) {
            editor.resetManualLogin()
            if editor.draft.kind != .pikPak { editor.login() }
          }
        }
      } else {
        if editor.draft.kind == .pikPak {
          EditorTextRow(editor: editor, key: "username", title: L("账号"), placeholder: L("邮箱或手机号"))
          EditorPasswordRow(editor: editor, title: L("密码"))
        }
        HStack {
          Text(L("登录后即可测试连接并保存位置。")).font(.callout).foregroundStyle(KayoiTheme.secondaryText)
          Spacer()
          Button(
            editor.draft.kind == .pikPak
              ? LF("登录%@", editor.draft.kind.title) : LF("登录%@…", editor.draft.kind.title)
          ) {
            editor.login()
          }
          .buttonStyle(FlatButtonStyle(prominent: true)).disabled(editor.busy)
        }
      }
      if editor.webService != nil && !ready {
        // 展开后的内容各占一行，和其他行一样排
        KayoiDisclosureButton(title: L("其他登录方式"), isExpanded: $alternatives)
        if alternatives {
          Toggle(L("手动粘贴登录信息"), isOn: $editor.manualLogin)
          if editor.manualLogin {
            Text(L("可以从浏览器复制当前网盘的登录信息并粘贴到这里。")).font(.caption).foregroundStyle(
              KayoiTheme.secondaryText)
            if editor.draft.kind == .mobileCloud {
              EditorTextRow(
                editor: editor, key: "phone", title: L("手机号"), placeholder: L("登录账号的手机号"))
            }
            EditorPasswordRow(editor: editor, title: L("登录信息"))
          }
        }
      }
      if editor.draft.kind == .tianyiDrive {
        Picker(L("空间"), selection: editor.parameter("scope")) {
          Text(L("个人云")).tag("personal")
          Text(L("家庭云")).tag("family")
        }.pickerStyle(.segmented).fixedSize().formRow(L("空间"))
        if editor.draft.params["scope"] == "family" {
          if editor.tianyiFamilySpaces.isEmpty {
            EditorTextRow(
              editor: editor, key: "familyID", title: L("家庭 ID"), placeholder: L("登录后选择或填写家庭 ID"))
          } else {
            Picker(L("家庭"), selection: editor.parameter("familyID")) {
              Text(L("选择家庭")).tag("")
              if let id = editor.draft.params["familyID"], !id.isEmpty,
                !editor.tianyiFamilySpaces.contains(where: { $0.familyID == id })
              {
                Text(LF("手动填写的家庭：%@", id)).tag(id)
              }
              ForEach(editor.tianyiFamilySpaces, id: \.familyID) { Text($0.name).tag($0.familyID) }
            }.formRow(L("家庭"))
          }
        }
      }
    }
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .quark, state: .blank) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .quark, state: .blank) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .quark, state: .filled) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .quark, state: .filled) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .quark, state: .error) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .quark, state: .error) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .quark, state: .testing) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .quark, state: .testing) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .quark, state: .success) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .quark, state: .success) { CloudConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}
