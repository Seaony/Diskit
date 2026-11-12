import Core
import SwiftUI

struct EditorEmptyState: View {
  let title: String
  let detail: String
  let symbol: String
  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(DiskitTheme.secondaryText).fixedSize(
          horizontal: false, vertical: true)
      }
    } icon: {
      Image(systemName: symbol).accessibilityHidden(true)
    }
    .padding(.vertical, Space.sm)
  }
}

#Preview("light · 空态") {
  EditorEmptyState(
    title: L("没有发现相机"), detail: L("请打开相机，使用数据线连接 Mac，并在相机上选择 PTP 或图像传输模式。"), symbol: "camera"
  ).padding().preferredColorScheme(.light)
}

#Preview("dark · 空态") {
  EditorEmptyState(
    title: L("没有发现相机"), detail: L("请打开相机，使用数据线连接 Mac，并在相机上选择 PTP 或图像传输模式。"), symbol: "camera"
  ).padding().preferredColorScheme(.dark)
}
