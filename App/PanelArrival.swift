import SwiftUI

struct PanelArrival: ViewModifier {
  let index: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  func body(content: Content) -> some View {
    content
      .opacity(appeared || reduceMotion ? 1 : 0)
      .offset(y: appeared || reduceMotion ? 0 : 8 * pow(0.7, Double(index))) // grid: ok 按下或拖动时的短暂位移
      .onAppear {
        guard !reduceMotion else { appeared = true; return }
        withAnimation(.easeOut(duration: 0.18).delay(0.024 * Double(index))) { appeared = true }
      }
  }
}
