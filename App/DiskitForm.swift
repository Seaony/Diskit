import SwiftUI

// 添加窗口的表单（对照设计稿）：分组是带细边框的卡片，每行上下留白一样、内容垂直居中；
// 带标题的行左边是固定宽的标题列，开关行标题在左、开关在右
struct DiskitFormSection<Content: View, Footer: View>: View {
  var title: String?
  let content: Content
  let footer: Footer

  init(title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.title = title
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous) // grid: ok 设计稿分组卡片圆角 10
    VStack(alignment: .leading, spacing: Space.sm) {
      if let title {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DiskitTheme.secondaryText)
          .padding(.horizontal, Space.xs)
      }
      Group(subviews: content) { rows in
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            // 每行上下留白相同，单行的行一律 44 高，分隔线两侧距离一样
            row.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading) // grid: ok 和输入框同高
              .padding(.horizontal, 14).padding(.vertical, Space.sm) // grid: ok 设计稿行左右 14
            // 行与行之间的分隔线，左右和行内容对齐
            if index < rows.count - 1 { DiskitSeparator().padding(.horizontal, 14) } // grid: ok 同行内边距
          }
        }
      }
      .background(DiskitTheme.surface, in: shape)
      .overlay { shape.strokeBorder(DiskitTheme.border, lineWidth: 0.5) }
      // 卡片下面的说明文字
      footer.font(.system(size: 12)).foregroundStyle(DiskitTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.xs)
    }
  }
}

extension DiskitFormSection where Footer == EmptyView {
  init(title: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title: title, content: content, footer: { EmptyView() })
  }
}

// 左边标题、右边控件，同一行里垂直居中；标题自带图标或控件高矮不一时用
struct DiskitSideRow<Label: View, Control: View>: View {
  let label: Label
  let control: Control

  init(@ViewBuilder control: () -> Control, @ViewBuilder label: () -> Label) {
    self.label = label()
    self.control = control()
  }

  var body: some View {
    HStack(spacing: Space.md) {
      label.font(.system(size: 13)).foregroundStyle(DiskitTheme.primaryText)
      Spacer(minLength: 0)
      control
    }
  }
}

extension DiskitSideRow where Label == Text {
  init(_ title: String, @ViewBuilder control: () -> Control) {
    self.init(control: control) { Text(title) }
  }
}

// 细分隔线：用边框色，比系统分隔线淡
struct DiskitSeparator: View {
  var body: some View {
    Rectangle().fill(DiskitTheme.border).frame(height: 0.5).accessibilityHidden(true) // grid: ok 细线
  }
}

// 标题列 110 宽，和控件按文字基线对齐；输入框把基线放在框内文字处，所以标题和框里的字齐平。
// 输入框撑满右边，选择器、色块这类不撑满的控件靠右
struct DiskitFormRow<Label: View, Content: View>: View {
  let label: Label
  let content: Content

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
      label.font(.system(size: 13)).foregroundStyle(DiskitTheme.primaryText)
        .frame(width: 110, alignment: .leading) // grid: ok 设计稿标题列宽 110
      content.frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

extension DiskitFormRow where Label == Text {
  // 不把标题当成控件的读屏名称：里面每个控件自己有名字时用（色块、配对码各位）
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(label: Text(title), content: content())
  }
}

struct DiskitFormRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    DiskitFormRow(label: configuration.label, content: configuration.content)
  }
}

// 开关行：说明文字占满左边，开关靠右
struct DiskitFormSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Space.lg) {
      configuration.label.font(.system(size: 13)).foregroundStyle(DiskitTheme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
    }
  }
}

// 可展开的行：箭头 + 标题，整行可点；展开内容按标题文字缩进 22
struct DiskitDisclosureButton: View {
  let title: String
  @Binding var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      withAnimation(Motion.change(reduceMotion: reduceMotion)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: Space.sm) {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(DiskitTheme.secondaryText)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 14) // grid: ok 箭头占位，展开内容按它缩进
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DiskitTheme.primaryText)
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
