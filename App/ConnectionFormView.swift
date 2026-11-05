import Core
import SwiftUI

struct ConnectionFormView: View {
  @Bindable var editor: ConnectionEditorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Form {
      Section {
        // 连接指南：整行可点，展开后按 1. 2. 3. 列出步骤（对照设计稿）
        VStack(alignment: .leading, spacing: 0) {
          Button {
            withAnimation(Motion.change(reduceMotion: reduceMotion)) { editor.preparationExpanded.toggle() }
          } label: {
            HStack(spacing: Space.sm) {
              Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KayoiTheme.secondaryText)
                .rotationEffect(.degrees(editor.preparationExpanded ? 90 : 0))
                .frame(width: 14) // grid: ok 箭头占位，展开内容按它缩进
              Text(L("连接指南")).font(.system(size: 13, weight: .medium)).foregroundStyle(KayoiTheme.primaryText)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain).pointerStyle(.link)
          .accessibilityAddTraits(editor.preparationExpanded ? .isSelected : [])
          if editor.preparationExpanded {
            VStack(alignment: .leading, spacing: 6) { // grid: ok 设计稿步骤间距 6
              ForEach(Array(EditorPreparation.steps(for: editor.draft.kind).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                  Text(verbatim: "\(index + 1).").font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(KayoiTheme.tertiaryText)
                  Text(Self.styledStep(step)).font(.system(size: 12.5)).foregroundStyle(KayoiTheme.secondaryText)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .padding(.leading, 22).padding(.top, Space.sm) // grid: ok 和标题文字左对齐
            .transition(Motion.appear(reduceMotion: reduceMotion))
          }
        }
      }
      Section(L("位置")) {
        Group {
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
        }.formRowSpacing()
      }
      Section(L("连接")) {
        Group {
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
        }.formRowSpacing()
      }
      if editor.draft.kind.usesSystemMount {
        Section(L("选项")) {
          Group {
            Toggle(L("打开 App 时自动挂载"), isOn: $editor.draft.autoMount)
            Toggle(L("挂载后自动在 Finder 中打开"), isOn: $editor.draft.openInFinderAfterMount)
          }.formRowSpacing()
        }
      }
    }
    .formStyle(.grouped).toggleStyle(.switch).scrollContentBackground(.hidden)
    .background(KayoiTheme.background)
    // 切换登录方式、列出共享、登录成功等会增减表单行，过渡一下
    .animation(Motion.change(reduceMotion: reduceMotion), value: formShape)
  }

  // 把指南文案里的标记换成样式，规则见 EditorPreparation
  private static func styledStep(_ source: String) -> AttributedString {
    guard
      let parsed = try? AttributedString(
        markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString(source) }
    // 标出的文字和前后文字之间留四分之一字宽；挨着标点、空格或在句首句尾时不加
    let gap = AttributedString("\u{2005}")
    func needsGap(_ character: Character?) -> Bool {
      guard let character else { return false }
      return !character.isWhitespace && !character.isPunctuation
    }
    let runs = Array(parsed.runs[\.inlinePresentationIntent])
    var text = AttributedString()
    for (index, (intent, range)) in runs.enumerated() {
      var piece = AttributedString(parsed[range])
      guard let intent else {
        text += piece
        continue
      }
      if intent.contains(.stronglyEmphasized) {
        piece.swiftUI.foregroundColor = KayoiTheme.primaryText
        piece.swiftUI.font = .system(size: 12.5, weight: .medium)
      } else if intent.contains(.emphasized) {
        piece.swiftUI.underlineStyle = Text.LineStyle(pattern: .dash, color: KayoiTheme.tertiaryText)
      } else if intent.contains(.strikethrough) {
        piece.swiftUI.foregroundColor = KayoiTheme.warning
      }
      // 不用 Markdown 默认的粗体、斜体、删除线
      piece.inlinePresentationIntent = nil
      if needsGap(text.characters.last) { text += gap }
      text += piece
      if index + 1 < runs.count, needsGap(parsed.characters[runs[index + 1].1.lowerBound]) { text += gap }
    }
    return text
  }

  // 决定表单有哪些行的选项；输入文字不在其中，打字时不触发动画
  private var formShape: [String] {
    [
      String(editor.guestLogin), String(editor.manualLogin), editor.draft.params["authMode"] ?? "",
      editor.draft.params["accountReady"] ?? "", editor.shares.joined(separator: "/"),
      editor.selectedDeviceID, editor.webdavPreset,
    ]
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
