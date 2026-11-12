import SwiftUI

// 设置里的单选：一组分段，每段按文字宽度，图标加文字；选中的那段用强调色实色填充，切换时滑过去
struct ChoiceButtons<Value: Hashable>: View {
  let options: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  let symbol: (Value) -> String
  // 只显示图标时，文字改作悬停提示和读屏名称
  var iconOnly = false
  @Namespace private var selectionSpace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 2) { // grid: ok 段与段之间留 2
      ForEach(options, id: \.self) { option in
        ChoiceSegment(
          title: title(option), symbol: symbol(option), iconOnly: iconOnly, selected: option == selection,
          space: selectionSpace
        ) {
          withAnimation(Motion.change(reduceMotion: reduceMotion)) { selection = option }
        }
      }
    }
    .padding(3) // grid: ok 外框和段之间留 3
    .background(DiskitTheme.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) // grid: ok 外框圆角 = 段圆角 7 + 间隙 3
  }
}

private struct ChoiceSegment: View {
  let title: String
  let symbol: String
  let iconOnly: Bool
  let selected: Bool
  let space: Namespace.ID
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous) // grid: ok 段圆角 7
    Button(action: action) {
      // 图标和文字靠近一些，系统 Label 的间距在这里显得松
      HStack(spacing: 6) { // grid: ok 图标与文字间距 6
        Image(systemName: symbol).accessibilityHidden(true)
        if !iconOnly { Text(title) }
      }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(selected ? DiskitTheme.actionText : DiskitTheme.primaryText)
        .padding(.horizontal, 14) // grid: ok 和按钮左右 14 一致
        .frame(height: 28) // grid: ok 和按钮同高
        .background {
          if selected {
            shape.fill(DiskitTheme.accent).matchedGeometryEffect(id: "selected", in: space)
          } else if hovering {
            shape.fill(DiskitTheme.primaryText.opacity(0.06))
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(.plain).pointerStyle(.link)
    .onHover { hovering = $0 }
    .help(Text(verbatim: iconOnly ? title : ""))
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

extension View {
  // 设置里的下拉菜单：不要底色，文字用正文颜色，窗口激活时也不染成强调色
  func menuPicker() -> some View {
    labelsHidden()
      .pickerStyle(.menu)
      .buttonStyle(.borderless)
      .tint(DiskitTheme.primaryText)
      .foregroundStyle(DiskitTheme.primaryText)
      .fixedSize()
      // 无边框菜单自带右侧留白，抵掉后箭头和同列其他控件右边对齐
      .padding(.trailing, -6) // grid: ok 抵消系统菜单右侧留白
      .pointerStyle(.link)
  }
}
