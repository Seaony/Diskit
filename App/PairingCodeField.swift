import Core
import SwiftUI

struct PairingCodeField: View {
  @Binding var code: String
  let onComplete: (String) -> Void
  @FocusState private var focused: Int?
  @State private var digits = Array(repeating: "", count: 6)
  var body: some View {
    HStack(spacing: Space.sm) {
      ForEach(0..<6, id: \.self) { index in
        TextField(
          "",
          text: Binding(
            get: { digits[index] },
            set: { input in
              digits = PairingDigits.replacing(input, at: index, in: digits)
              let value = digits.joined()
              code = value
              if value.count == 6 {
                focused = nil
                onComplete(value)
              } else if !input.isEmpty {
                focused = min(index + PairingDigits.normalized(input).count, 5)
              }
            })
        )
        .textFieldStyle(.roundedBorder).font(.body.monospacedDigit()).multilineTextAlignment(
          .center
        )
        .frame(width: 32).focused($focused, equals: index)
        .textContentType(.oneTimeCode)
        .accessibilityLabel(LF("配对码第 %lld 位", Int64(index + 1)))
        .onKeyPress(.delete) {
          if digits[index].isEmpty, index > 0 {
            focused = index - 1
            digits[index - 1] = ""
            code = digits.joined()
            return .handled
          }
          return .ignored
        }
      }
    }
    .task { synchronize() }
    .onChange(of: code) { _, _ in
      if code != digits.joined() {
        synchronize()
        if code.isEmpty { focused = 0 }
      }
    }
  }
  private func synchronize() {
    digits = PairingDigits.replacing(code, at: 0, in: Array(repeating: "", count: 6))
  }
}

#Preview("light · 空白") {
  PairingCodeField(code: .constant(""), onComplete: { _ in }).padding().preferredColorScheme(.light)
}

#Preview("dark · 空白") {
  PairingCodeField(code: .constant(""), onComplete: { _ in }).padding().preferredColorScheme(.dark)
}
