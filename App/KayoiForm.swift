import SwiftUI

// 添加窗口的表单（对照设计稿）：分组是带细边框的卡片，每行上下留白一样、内容垂直居中；
// 带标题的行左边是固定宽的标题列，开关行标题在左、开关在右
struct KayoiFormSection<Content: View>: View {
  var title: String?
  @ViewBuilder var content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous) // grid: ok 设计稿分组卡片圆角 10
    VStack(alignment: .leading, spacing: Space.sm) {
      if let title {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(KayoiTheme.secondaryText)
          .padding(.horizontal, Space.xs)
      }
      Group(subviews: content) { rows in
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            row.frame(maxWidth: .infinity, minHeight: 26, alignment: .leading) // grid: ok 加上下 6 正好 38 高
              .padding(.horizontal, 14).padding(.vertical, 6) // grid: ok 设计稿行内边距 6/14
            // 行与行之间的分隔线，左右和行内容对齐
            if index < rows.count - 1 { KayoiSeparator().padding(.horizontal, 14) } // grid: ok 同行内边距
          }
        }
      }
      .padding(.vertical, Space.xs)
      .background(KayoiTheme.surface, in: shape)
      .overlay { shape.strokeBorder(KayoiTheme.border, lineWidth: 0.5) }
    }
  }
}

// 细分隔线：用边框色，比系统分隔线淡
struct KayoiSeparator: View {
  var body: some View {
    Rectangle().fill(KayoiTheme.border).frame(height: 0.5).accessibilityHidden(true) // grid: ok 细线
  }
}

// 标题列 110 宽，和控件按文字基线对齐；输入框把基线放在框内文字处，所以标题和框里的字齐平
struct KayoiFormRow<Label: View, Content: View>: View {
  let label: Label
  let content: Content

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
      label.font(.system(size: 13)).foregroundStyle(KayoiTheme.primaryText)
        .frame(width: 110, alignment: .leading) // grid: ok 设计稿标题列宽 110
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension KayoiFormRow where Label == Text {
  // 不把标题当成控件的读屏名称：里面每个控件自己有名字时用（色块、配对码各位）
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(label: Text(title), content: content())
  }
}

struct KayoiFormRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    KayoiFormRow(label: configuration.label, content: configuration.content)
  }
}

// 开关行：说明文字占满左边，开关靠右
struct KayoiFormSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Space.lg) {
      configuration.label.font(.system(size: 13)).foregroundStyle(KayoiTheme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
    }
  }
}

// 可展开的行：箭头 + 标题，整行可点；展开内容按标题文字缩进 22
struct KayoiDisclosureButton: View {
  let title: String
  @Binding var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      withAnimation(Motion.change(reduceMotion: reduceMotion)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: Space.sm) {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(KayoiTheme.secondaryText)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 14) // grid: ok 箭头占位，展开内容按它缩进
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(KayoiTheme.primaryText)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).pointerStyle(.link)
    // 读屏读出当前是展开还是收起
    .accessibilityValue(isExpanded ? L("已展开") : L("已收起"))
  }
}

extension View {
  // 选择器等自带标题的控件放进标题列布局；控件自己的标题藏起来，读屏仍能读到
  func formRow(_ title: String) -> some View { LabeledContent(title) { labelsHidden() } }
}
