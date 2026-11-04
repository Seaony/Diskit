import Core
import SwiftUI

struct ConnectionTypeTile: View {
  let kind: ConnectionKind
  // 分组标题已写明“实验性”时不再逐个标
  var marksExperimental = true
  var body: some View {
    VStack(spacing: Space.xs) {
      TypeIcon(kind: kind, size: 40)
      Text(kind.title).font(.body.weight(.medium)).lineLimit(1)
    }
    .padding(.horizontal, Space.sm)
    .frame(maxWidth: .infinity).frame(height: 88)
    .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    .overlay(alignment: .topTrailing) {
      if (kind.isExperimental && marksExperimental) || kind == .lanzou {
        Text(kind == .lanzou ? L("只读") : L("实验性"))
          .font(.caption2).foregroundStyle(KayoiTheme.secondaryText)
          .padding(Space.xs).background(KayoiTheme.surface, in: Capsule())
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
    ConnectionTypeTile(kind: .smb)
  }.buttonStyle(ConnectionCardStyle(selected: true)).frame(width: 136).padding()
    .preferredColorScheme(.light)
}

#Preview("类型格子 · 选中 · 深色") {
  Button {
  } label: {
    ConnectionTypeTile(kind: .smb)
  }.buttonStyle(ConnectionCardStyle(selected: true)).frame(width: 136).padding()
    .preferredColorScheme(.dark)
}
