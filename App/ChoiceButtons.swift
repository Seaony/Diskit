import SwiftUI

// 设置里的单选：等宽按钮铺满一行，图标加文字，选中的用强调色实色填充
struct ChoiceButtons<Value: Hashable>: View {
  let options: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  let symbol: (Value) -> String

  var body: some View {
    HStack(spacing: Space.sm) {
      ForEach(options, id: \.self) { option in
        let selected = option == selection
        Button {
          selection = option
        } label: {
          Label(title(option), systemImage: symbol(option))
            .frame(maxWidth: .infinity, minHeight: 32) // grid: ok 比普通按钮高一档
        }
        .buttonStyle(FlatButtonStyle(prominent: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }
}
