import Core
import SwiftUI

struct AndroidConnectionForm: View {
  @Bindable var editor: ConnectionEditorModel
  var body: some View {
    // 只开了文件传输的设备（MTP）也算“USB 数据线”，用户不用分辨两种协议
    let usb = editor.draft.kind == .androidUSB || editor.draft.kind == .androidMTP
    Picker(
      L("连接方式"),
      selection: Binding(
        get: { usb ? ConnectionKind.androidUSB : editor.draft.kind },
        set: { if !($0 == .androidUSB && usb) { editor.choose($0) } })
    ) {
      Text(L("USB 数据线")).tag(ConnectionKind.androidUSB)
      Text(L("无线调试")).tag(ConnectionKind.androidWiFi)
    }.pickerStyle(.segmented).fixedSize().formRow(L("连接方式"))
    if usb {
      let debugging = editor.model.usbDevices
      let transfer = editor.model.transferOnlyDevices
      if debugging.isEmpty && transfer.isEmpty {
        EditorEmptyState(
          title: L("没有发现 Android 设备"),
          detail: L("请使用支持数据传输的线缆连接，解锁设备，并在设备的 USB 选项里选“文件传输”。"),
          symbol: "cable.connector")
      } else {
        Picker(
          L("设备"),
          selection: Binding(get: { editor.selectedDeviceID }, set: { editor.selectDevice($0) })
        ) {
          Text(L("选择设备")).tag("")
          if !editor.selectedDeviceID.isEmpty,
            !debugging.contains(where: { $0.id == editor.selectedDeviceID }),
            !transfer.contains(where: { $0.id == editor.selectedDeviceID })
          {
            Text(L("已保存的设备（当前未发现）")).tag(editor.selectedDeviceID)
          }
          ForEach(debugging) { device in
            Text(
              device.serial.isEmpty
                ? device.name : LF("%@（%@）", device.name, String(device.serial.suffix(4)))
            ).tag(device.id)
          }
          ForEach(transfer) { device in
            Text(LF("%@ · 文件传输", device.name)).tag(device.id)
          }
        }.formRow(L("设备"))
      }
    } else if editor.draft.params["guid"] != nil {
      Label(L("配对成功"), systemImage: "checkmark.circle.fill").foregroundStyle(DiskitTheme.accent)
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
        }.formRow(L("设备"))
        DiskitFormRow(L("六位配对码")) {
          PairingCodeField(code: $editor.pairingCode, onComplete: editor.updatePairingCode)
        }
        Text(L("输入完整配对码后会自动配对。")).font(.caption).foregroundStyle(DiskitTheme.secondaryText)
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
