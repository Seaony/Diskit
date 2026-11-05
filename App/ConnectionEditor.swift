import AppKit
import Core
import SwiftUI

struct ConnectionEditor: View {
  @State private var editor: ConnectionEditorModel
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: AppModel) {
    _editor = State(
      initialValue: ConnectionEditorModel(
        model: model, oauthFactory: { WebAuthorization(window: $0) },
        webFactory: { WebLoginWindowController() }))
  }

  var body: some View {
    // 两步各占一页：选好类型后表单从右边滑入，上一步时类型页从左边滑回
    ZStack {
      if editor.chosen {
        VStack(spacing: 0) {
          HStack(spacing: Space.md) {
            TypeIcon(kind: editor.draft.kind, color: editor.draft.color, size: 44)
            VStack(alignment: .leading, spacing: 3) { // grid: ok 标题与说明贴近
              Text(editor.draft.kind.title).font(.system(size: 14, weight: .semibold))
              Text(ConnectionTypeCatalog.caption(editor.draft.kind)).font(.system(size: 11))
                .foregroundStyle(KayoiTheme.secondaryText)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 28).padding(.top, Space.sm) // grid: ok 设计稿第二步左右 28
          ConnectionFormView(editor: editor).disabled(editor.busy)
          // 底部操作栏和可滚动的表单之间用分割线隔开，左右和表单卡片对齐
          KayoiSeparator().padding(.horizontal, 28) // grid: ok 同表单左右 28
          footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KayoiTheme.background)
        .transition(Motion.push(from: .trailing, reduceMotion: reduceMotion))
      } else {
        VStack(spacing: 0) {
          ConnectionTypePicker(editor: editor)
            // 第一步没有底部按钮，Esc 仍然关闭窗口
            .background {
              Button(L("关闭")) { dismissWindow(id: "connection") }
                .keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true)
            }
          if editor.visibleError != nil { footer }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KayoiTheme.background)
        .transition(Motion.push(from: .leading, reduceMotion: reduceMotion))
      }
    }
    .clipped()
    .animation(Motion.page(reduceMotion: reduceMotion), value: editor.chosen)
    .buttonStyle(FlatButtonStyle())
    .tint(KayoiTheme.accent)
    .background(KayoiTheme.background)
    .frame(width: 576).frame(minHeight: 520)
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
          .transition(Motion.appear(reduceMotion: reduceMotion))
      }
      if editor.visibleError != nil {
        EditorErrorBanner(editor: editor).transition(Motion.appear(reduceMotion: reduceMotion))
      }
      if editor.chosen { actions }
    }.padding(Space.xl).gridArea("editor-footer", inset: Space.xl)
    .animation(Motion.change(reduceMotion: reduceMotion), value: editor.testSucceeded)
    .animation(Motion.change(reduceMotion: reduceMotion), value: editor.visibleError)
    .animation(Motion.change(reduceMotion: reduceMotion), value: editor.busy)
  }

  private var actions: some View {
    HStack(spacing: Space.sm) {
      if !editor.isEditing {
        Button { editor.showTypes() } label: { Label(L("上一步"), systemImage: "chevron.left") }
          .disabled(editor.busy)
      }
      if editor.busy {
        ProgressView().nativeProgressAppearance().controlSize(.small)
        Text(editor.stage ?? L("正在连接…")).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
          .lineLimit(2)
      }
      Spacer(minLength: Space.sm)
      // 只在连接中显示取消，用来中止；平时关窗口用关闭按钮或 Esc
      if editor.busy {
        Button { editor.cancelWork() } label: { Label(L("取消"), systemImage: "xmark") }
      }
      Button(L("关闭")) {
        if editor.busy { editor.cancelWork() } else { dismissWindow(id: "connection") }
      }
      .keyboardShortcut(.cancelAction).hidden().frame(width: 0, height: 0).accessibilityHidden(true)
      Button { editor.save() } label: { Label(L("测试并保存"), systemImage: "checkmark.circle.fill") }
        .buttonStyle(FlatButtonStyle(prominent: editor.hasRequiredLogin))
        .disabled(!editor.canSave)
        .keyboardShortcut(.defaultAction)
        .help(L("测试并保存（Return / ⌘Return）"))
      Button(L("测试并保存")) { editor.save() }
        .keyboardShortcut(.return, modifiers: .command).hidden().frame(width: 0, height: 0)
        .accessibilityHidden(true).disabled(!editor.canSave)
    }
    .labelStyle(.titleAndIcon)
    .gridProbe("footer-actions", area: "editor-footer")
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
