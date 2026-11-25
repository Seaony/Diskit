import Core
import SwiftUI

struct CameraConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    if editor.model.cameraUSBDevices.isEmpty {
      empty
    } else {
      Picker(
        L("相机"),
        selection: Binding(get: { editor.selectedDeviceID }, set: { editor.selectDevice($0) })
      ) {
        Text(L("选择相机")).tag("")
        if !editor.selectedDeviceID.isEmpty,
          !editor.model.cameraUSBDevices.contains(where: { $0.id == editor.selectedDeviceID })
        {
          Text(L("已保存的相机（当前未发现）")).tag(editor.selectedDeviceID)
        }
        ForEach(editor.model.cameraUSBDevices) { Text($0.name).tag($0.id) }
      }.formRow(L("相机"))
    }
  }
  private var empty: some View {
    EditorEmptyState(
      title: L("没有发现相机"), detail: L("请打开相机，使用数据线连接 Mac，并在相机上选择 PTP 或图像传输模式。"), symbol: "camera")
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .cameraUSB, state: .blank) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .cameraUSB, state: .blank) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .cameraUSB, state: .filled) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .cameraUSB, state: .filled) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .cameraUSB, state: .error) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .cameraUSB, state: .error) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .cameraUSB, state: .testing) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .cameraUSB, state: .testing) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .cameraUSB, state: .success) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .cameraUSB, state: .success) { CameraConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}
