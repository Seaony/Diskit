import SwiftUI

// 表单输入框：高 28、圆角和搜索框一致、浅填充加细边；正在输入时换成焦点色描边
private struct KayoiFieldModifier: ViewModifier {
  let focused: Bool
  let horizontalPadding: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
    content
      .textFieldStyle(.plain)
      .padding(.horizontal, horizontalPadding)
      .frame(height: 28) // grid: ok 设计稿输入框高 28
      .background(KayoiTheme.field, in: shape)
      .overlay {
        shape.strokeBorder(focused ? KayoiTheme.focus : KayoiTheme.border, lineWidth: focused ? 2 : 0.5)
      }
      .animation(Motion.hover(reduceMotion: reduceMotion), value: focused)
      // 加高后表单拿到的基线偏上，左边标签会高出一截；按 13 号字在框内居中时的基线对齐
      .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 } // grid: ok 13 号字基线在中线下 4
      .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 } // grid: ok 同上
  }
}

extension View {
  func kayoiField(focused: Bool, horizontalPadding: CGFloat = 10) -> some View { // grid: ok 设计稿输入框左右 10
    modifier(KayoiFieldModifier(focused: focused, horizontalPadding: horizontalPadding))
  }
}
