import Core
import SwiftUI

struct ConnectionFormView: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    Form {
      Section {
        DisclosureGroup(L("准备步骤"), isExpanded: $editor.preparationExpanded) {
          VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(EditorPreparation.steps(for: editor.draft.kind), id: \.self) { step in
              Text(step).font(.callout).foregroundStyle(KayoiTheme.secondaryText).fixedSize(
                horizontal: false, vertical: true)
            }
          }.padding(.vertical, Space.sm)
        }
      }
      Section(L("位置")) {
        EditorTextRow(editor: editor, key: "name", title: L("显示名称"), placeholder: L("例如：我的手机"))
        LabeledContent(L("图标颜色")) {
          HStack(spacing: Space.sm) {
            ForEach(KayoiTheme.locationColorNames, id: \.self) { name in
              Button {
                editor.draft.color = name
              } label: {
                // 选中色用同色外圈标出，不加勾
                Circle().fill(KayoiTheme.locationColor(name)).frame(width: 18, height: 18)
                  .padding(3) // grid: ok 色块与外圈间隙
                  .overlay {
                    Circle().strokeBorder(editor.draft.color == name ? KayoiTheme.locationColor(name) : .clear, lineWidth: 2)
                  }
                  .contentShape(Circle())
              }.buttonStyle(.plain).pointerStyle(.link).help(EditorPreparation.colorName(name)).accessibilityLabel(
                EditorPreparation.colorName(name)
              )
              .accessibilityAddTraits(editor.draft.color == name ? .isSelected : [])
            }
          }
        }
      }
      Section(L("连接")) {
        switch editor.draft.kind {
        case .androidUSB, .androidWiFi: AndroidConnectionForm(editor: editor)
        case .ricohGR, .cameraUSB: CameraConnectionForm(editor: editor)
        case .smb: SMBConnectionForm(editor: editor)
        case .webdav, .webdavHTTPS: WebDAVConnectionForm(editor: editor)
        case .nfs: NFSConnectionForm(editor: editor)
        case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
          ObjectStorageConnectionForm(editor: editor)
        default: CloudConnectionForm(editor: editor)
        }
      }
      if editor.draft.kind.usesSystemMount {
        Section(L("选项")) {
          Toggle(L("打开 App 时自动挂载"), isOn: $editor.draft.autoMount)
          Toggle(L("挂载后自动在 Finder 中打开"), isOn: $editor.draft.openInFinderAfterMount)
        }
      }
    }
    .formStyle(.grouped).toggleStyle(.switch).scrollContentBackground(.hidden)
    .background(KayoiTheme.background)
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .smb, state: .blank, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .smb, state: .blank, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .smb, state: .filled, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .smb, state: .filled, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .smb, state: .error, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .smb, state: .error, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .smb, state: .testing, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .smb, state: .testing, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .smb, state: .success, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .smb, state: .success, inForm: false) { ConnectionFormView(editor: $0) }
    .preferredColorScheme(.dark)
}
