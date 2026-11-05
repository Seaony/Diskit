import Core
import SwiftUI

struct ConnectionTypeTile: View {
  let kind: ConnectionKind
  // 已发现的设备显示设备名，类型显示类型名
  var title: String? = nil
  // 名字下面的一行说明；不传就用类型自带的说明
  var subtitle: String? = nil
  var selected = false

  // 非官方接口的网盘标 Beta，官方网盘标授权方式，其余用类型说明
  private var defaultSubtitle: String {
    if kind.isExperimental { return "Beta" }
    if kind.isCloud { return L("官方授权") }
    return ConnectionTypeCatalog.caption(kind)
  }

  var body: some View {
    VStack(spacing: Space.sm) {
      TypeIcon(kind: kind, size: 30)
      VStack(spacing: 2) { // grid: ok 名字和说明贴近
        Text(title ?? kind.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
          .foregroundStyle(selected ? KayoiTheme.accent : KayoiTheme.primaryText)
        Text(subtitle ?? defaultSubtitle).font(.system(size: 10)).lineLimit(1)
          .foregroundStyle(KayoiTheme.secondaryText)
      }
    }
    .padding(.horizontal, 10) // grid: ok 设计稿格子左右 10
    .frame(maxWidth: .infinity).frame(height: 84)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

#Preview("类型格子 · 默认 · 浅色") {
  Button {
  } label: {
    ConnectionTypeTile(kind: .smb)
  }.buttonStyle(ConnectionCardStyle(selected: false)).frame(width: 136).padding()
    .preferredColorScheme(.light)
}

#Preview("类型格子 · 默认 · 深色") {
  Button {
  } label: {
    ConnectionTypeTile(kind: .smb)
  }.buttonStyle(ConnectionCardStyle(selected: false)).frame(width: 136).padding()
    .preferredColorScheme(.dark)
}

#Preview("类型格子 · 选中 · 浅色") {
  Button {
  } label: {
    ConnectionTypeTile(kind: .smb, selected: true)
  }.buttonStyle(ConnectionCardStyle(selected: true)).frame(width: 136).padding()
    .preferredColorScheme(.light)
}

#Preview("类型格子 · 选中 · 深色") {
  Button {
  } label: {
    ConnectionTypeTile(kind: .quark, selected: true)
  }.buttonStyle(ConnectionCardStyle(selected: true)).frame(width: 136).padding()
    .preferredColorScheme(.dark)
}
