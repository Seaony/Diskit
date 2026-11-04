import Core
import SwiftUI

struct ConnectionTypeTile: View {
  let kind: ConnectionKind
  // 已发现的设备显示设备名，类型显示类型名
  var title: String? = nil
  // 实验性网盘分组里右上角标“实验”
  var marksExperimental = false
  var selected = false
  var body: some View {
    VStack(spacing: Space.sm) {
      TypeIcon(kind: kind, size: 34)
      Text(title ?? kind.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
        .foregroundStyle(selected ? KayoiTheme.accent : KayoiTheme.primaryText)
    }
    .padding(.horizontal, 10) // grid: ok 设计稿格子左右 10
    .frame(maxWidth: .infinity).frame(height: 84)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(alignment: .topTrailing) {
      if marksExperimental {
        Text(L("实验")).font(.system(size: 10)).foregroundStyle(KayoiTheme.tertiaryText)
          .padding(.top, 6).padding(.trailing, Space.sm) // grid: ok 设计稿角标位置
      }
    }
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
    ConnectionTypeTile(kind: .quark, marksExperimental: true, selected: true)
  }.buttonStyle(ConnectionCardStyle(selected: true)).frame(width: 136).padding()
    .preferredColorScheme(.dark)
}
