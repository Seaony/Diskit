import Core
import SwiftUI

struct EditorErrorBanner: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    if let error = editor.visibleError {
      HStack(alignment: .top, spacing: Space.sm) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(KayoiTheme.error).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Space.xs) {
          Text(L("连接未完成")).font(.headline)
          Text(error).font(.callout).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: Space.sm) {
            Button(editor.errorNeedsLogin ? L("重新登录") : L("重试")) {
              if editor.errorNeedsLogin || editor.lastActionWasLogin {
                editor.login()
              } else {
                editor.save()
              }
            }.disabled(editor.busy)
            if editor.permissionSettingsURL != nil {
              Button(L("打开系统设置")) { editor.openPermissionSettings() }
            }
            Button(L("复制详细信息")) { editor.copy(error) }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(Space.md)
      .background(
        KayoiTheme.errorBackground,
        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
  }
}

#Preview("连接错误 · 浅色") {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
  editor.applyDemoFixture(kind: .quark, state: .error)
  editor.errorNeedsLogin = false
  return EditorErrorBanner(editor: editor).padding().frame(width: 600).preferredColorScheme(.light)
}

#Preview("连接错误 · 深色") {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
  editor.applyDemoFixture(kind: .quark, state: .error)
  editor.errorNeedsLogin = false
  return EditorErrorBanner(editor: editor).padding().frame(width: 600).preferredColorScheme(.dark)
}

#Preview("登录失效 · 浅色") {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
  editor.applyDemoFixture(kind: .quark, state: .error)
  editor.errorNeedsLogin = true
  return EditorErrorBanner(editor: editor).padding().frame(width: 600).preferredColorScheme(.light)
}

#Preview("登录失效 · 深色") {
  let editor = ConnectionEditorModel(
    model: AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"])))
  editor.applyDemoFixture(kind: .quark, state: .error)
  editor.errorNeedsLogin = true
  return EditorErrorBanner(editor: editor).padding().frame(width: 600).preferredColorScheme(.dark)
}
