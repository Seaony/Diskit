import SwiftUI

struct EmptyLocationIcon: View {
  var size: CGFloat = 64
  var body: some View {
    Image("TypeIcon-emptyLink-blue")
      .renderingMode(.original)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
