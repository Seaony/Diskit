import AppKit
import Core
import SwiftUI

struct ConnectionEditor: View {
  @State private var editor: ConnectionEditorModel
  @Environment(\.dismissWindow) private var dismissWindow

  init(model: AppModel) {
    _editor = State(
      initialValue: ConnectionEditorModel(
        model: model, oauthFactory: { WebAuthorization(window: $0) },
        webFactory: { WebLoginWindowController() }))
  }

  var body: some View {
    VStack(spacing: 0) {
      if editor.chosen {
        HStack(spacing: Space.md) {
          TypeIcon(kind: editor.draft.kind, color: editor.draft.color, size: 44)
          VStack(alignment: .leading, spacing: 3) { // grid: ok 标题与说明贴近
            Text(editor.draft.kind.title).font(.system(size: 17, weight: .semibold))
            Text(ConnectionTypeCatalog.caption(editor.draft.kind)).font(.system(size: 12))
              .foregroundStyle(KayoiTheme.secondaryText)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.top, Space.sm) // grid: ok 设计稿第二步左右 28
        ConnectionFormView(editor: editor).disabled(editor.busy)
      } else {
        ConnectionTypePicker(editor: editor)
          // 第一步没有底部按钮，Esc 仍然关闭窗口
          .background {
            Button(L("关闭")) { dismissWindow(id: "connection") }
              .keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true)
          }
      }
      if editor.chosen || editor.visibleError != nil { footer }
    }
    .buttonStyle(FlatButtonStyle())
    .tint(KayoiTheme.accent)
    .background(KayoiTheme.background)
    .frame(width: 480).frame(minHeight: 520)
    .gridDiagnostics("editor")
    .demoAppearanceEvidence("editor")
    .background(
      EditorWindowAccessor { window in
        editor.anchorWindow = window
        editor.synchronizeWindowTitle()
        if !editor.model.options.isDemo { window.setFrameAutosaveName("Kayoi.ConnectionEditor") }
      }
    )
    .task(id: editor.model.demoEditorRevision) {
      editor.load()
      await editor.applyRequestedDemoState()
    }
    .onChange(of: editor.windowTitle) { _, _ in editor.synchronizeWindowTitle() }
    .onChange(of: editor.didSave) { _, saved in
      if saved { dismissWindow(id: "connection") }
    }
    .onChange(of: editor.chosen) { _, chosen in
      if chosen { editor.anchorWindow?.makeFirstResponder(nil) }
    }
    .onChange(of: editor.model.usbDevices.map(\.id)) { _, _ in editor.autoSelectDevice() }
    .onChange(of: editor.model.ricohDevices.map(\.id)) { _, _ in editor.autoSelectDevice() }
    .onChange(of: editor.model.cameraUSBDevices.map(\.id)) { _, _ in editor.autoSelectDevice() }
    .onDisappear { editor.cancelWork() }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      if editor.testSucceeded {
        Label(L("连接测试成功"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(KayoiTheme.accent).font(.callout)
      }
      EditorErrorBanner(editor: editor)
      if editor.chosen { actions }
    }.padding(Space.xl).gridArea("editor-footer", inset: Space.xl)
  }

  private var actions: some View {
    HStack(spacing: Space.sm) {
      if !editor.isEditing {
        Button(L("上一步")) { editor.showTypes() }.disabled(editor.busy)
      }
      if editor.busy {
        ProgressView().nativeProgressAppearance().controlSize(.small)
        Text(editor.stage ?? L("正在连接…")).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
          .lineLimit(2)
      } else if let missing = editor.missingFieldsDescription {
        Text(missing).font(.caption).foregroundStyle(KayoiTheme.secondaryText).lineLimit(2)
      }
      Spacer(minLength: Space.sm)
      Button(L("取消")) {
        if editor.busy { editor.cancelWork() } else { dismissWindow(id: "connection") }
      }.keyboardShortcut(.cancelAction)
      Button(L("测试并保存")) { editor.save() }
        .buttonStyle(FlatButtonStyle(prominent: editor.hasRequiredLogin))
        .disabled(!editor.canSave)
        .keyboardShortcut(.defaultAction)
        .help(L("测试并保存（Return / ⌘Return）"))
      Button(L("测试并保存")) { editor.save() }
        .keyboardShortcut(.return, modifiers: .command).hidden().frame(width: 0, height: 0)
        .accessibilityHidden(true).disabled(!editor.canSave)
    }.gridProbe("footer-actions", area: "editor-footer")
  }
}

private struct EditorWindowAccessor: NSViewRepresentable {
  let update: @MainActor (NSWindow) -> Void
  func makeNSView(context: Context) -> WindowView { WindowView(update: update) }
  func updateNSView(_ nsView: WindowView, context: Context) { nsView.update = update }
  @MainActor final class WindowView: NSView {
    var update: @MainActor (NSWindow) -> Void
    init(update: @escaping @MainActor (NSWindow) -> Void) {
      self.update = update
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { update(window) }
    }
  }
}

#Preview("类型选择") {
  ConnectionEditor(model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
}

#Preview("类型选择 · 深色") {
  ConnectionEditor(model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
    .preferredColorScheme(.dark)
}

#Preview("SMB 表单") {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  var connection = Connection()
  connection.kind = .smb
  connection.name = "我的 SMB 共享"
  model.editing = connection
  return ConnectionEditor(model: model)
}

#Preview("SMB 表单 · 深色") {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  var connection = Connection()
  connection.kind = .smb
  connection.name = "我的 SMB 共享"
  model.editing = connection
  return ConnectionEditor(model: model).preferredColorScheme(.dark)
}

#Preview("编辑器 · 空白 · 浅色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "blank",
      ]))
  ).preferredColorScheme(.light)
}
#Preview("编辑器 · 空白 · 深色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "blank",
      ]))
  ).preferredColorScheme(.dark)
}
#Preview("编辑器 · 填写 · 浅色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "filled",
      ]))
  ).preferredColorScheme(.light)
}
#Preview("编辑器 · 填写 · 深色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "filled",
      ]))
  ).preferredColorScheme(.dark)
}
#Preview("编辑器 · 错误 · 浅色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "error",
      ]))
  ).preferredColorScheme(.light)
}
#Preview("编辑器 · 错误 · 深色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "error",
      ]))
  ).preferredColorScheme(.dark)
}
#Preview("编辑器 · 测试中 · 浅色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "testing",
      ]))
  ).preferredColorScheme(.light)
}
#Preview("编辑器 · 测试中 · 深色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "testing",
      ]))
  ).preferredColorScheme(.dark)
}
#Preview("编辑器 · 成功 · 浅色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "success",
      ]))
  ).preferredColorScheme(.light)
}
#Preview("编辑器 · 成功 · 深色") {
  ConnectionEditor(
    model: AppModel(
      options: RuntimeOptions(environment: [
        "KAYOI_DEMO": "1", "KAYOI_DEMO_EDITOR_TYPE": "smb", "KAYOI_DEMO_EDITOR_STATE": "success",
      ]))
  ).preferredColorScheme(.dark)
}
