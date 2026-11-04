import Core
import SwiftUI

struct AndroidConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    Picker(L("连接方式"), selection: Binding(get: { editor.draft.kind }, set: { editor.choose($0) })) {
      Text(L("USB 数据线")).tag(ConnectionKind.androidUSB)
      Text(L("无线调试")).tag(ConnectionKind.androidWiFi)
    }.pickerStyle(.segmented)
    if editor.draft.kind == .androidUSB {
      if editor.model.usbDevices.isEmpty {
        EditorEmptyState(
          title: L("没有发现安卓设备"), detail: L("请使用支持数据传输的线缆，解锁手机并开启 USB 调试。首次连接时，请在手机上允许这台电脑。"),
          symbol: "cable.connector")
      } else {
        Picker(
          L("设备"),
          selection: Binding(get: { editor.selectedDeviceID }, set: { editor.selectDevice($0) })
        ) {
          Text(L("选择设备")).tag("")
          if !editor.selectedDeviceID.isEmpty,
            !editor.model.usbDevices.contains(where: { $0.id == editor.selectedDeviceID })
          {
            Text(L("已保存的设备（当前未发现）")).tag(editor.selectedDeviceID)
          }
          ForEach(editor.model.usbDevices) { device in
            Text(
              device.serial.isEmpty
                ? device.name : LF("%@（%@）", device.name, String(device.serial.suffix(4)))
            ).tag(device.id)
          }
        }
      }
    } else if editor.draft.params["guid"] != nil {
      Label(L("配对成功"), systemImage: "checkmark.circle.fill").foregroundStyle(KayoiTheme.accent)
    } else {
      let devices = editor.model.wirelessDevices.filter { $0.type == .pairing }
      if devices.isEmpty {
        EditorEmptyState(
          title: L("没有发现配对设备"),
          detail: L("请让手机和 Mac 连接同一 Wi-Fi，在手机的无线调试设置中打开“使用配对码配对设备”，并保持该页面开启。"), symbol: "wifi")
      } else {
        Picker(L("设备"), selection: $editor.pairingID) {
          Text(L("选择配对设备")).tag("")
          if !editor.pairingID.isEmpty, !devices.contains(where: { $0.id == editor.pairingID }) {
            Text(L("已选择的配对设备（当前未发现）")).tag(editor.pairingID)
          }
          ForEach(devices) { Text($0.name).tag($0.id) }
        }
        LabeledContent(L("六位配对码")) {
          PairingCodeField(code: $editor.pairingCode, onComplete: editor.updatePairingCode)
        }
        Text(L("输入完整配对码后会自动配对。")).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
      }
    }
  }
}

#Preview("空白 · 浅色") {
  EditorPreview(kind: .androidUSB, state: .blank) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("空白 · 深色") {
  EditorPreview(kind: .androidUSB, state: .blank) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("填写 · 浅色") {
  EditorPreview(kind: .androidUSB, state: .filled) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("填写 · 深色") {
  EditorPreview(kind: .androidUSB, state: .filled) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("错误 · 浅色") {
  EditorPreview(kind: .androidUSB, state: .error) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("错误 · 深色") {
  EditorPreview(kind: .androidUSB, state: .error) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("测试中 · 浅色") {
  EditorPreview(kind: .androidUSB, state: .testing) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("测试中 · 深色") {
  EditorPreview(kind: .androidUSB, state: .testing) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("成功 · 浅色") {
  EditorPreview(kind: .androidUSB, state: .success) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("成功 · 深色") {
  EditorPreview(kind: .androidUSB, state: .success) { AndroidConnectionForm(editor: $0) }
    .preferredColorScheme(.dark)
}
