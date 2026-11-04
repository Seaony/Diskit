import Core
import SwiftUI

struct SettingsLicenseView: View {
  let document: SettingsLicense
  @Environment(\.dismiss) private var dismiss
  @State private var text: String?
  @State private var error: String?
  @State private var reload = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(document.title).font(.headline)
        Spacer()
        Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .gridProbe("heading", area: "license", edge: nil)
      .padding(Space.margin)
      Divider()
      if let text {
        ScrollView {
          Text(text).font(.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridProbe("license-text", area: "license", edge: nil)
            .padding(Space.margin)
        }
      } else if let error {
        VStack(alignment: .leading, spacing: Space.md) {
          Label(L("无法打开许可证"), systemImage: "exclamationmark.circle")
            .font(.headline).foregroundStyle(KayoiTheme.error)
          Text(error).fixedSize(horizontal: false, vertical: true)
          Button(L("重试")) { reload += 1 }
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ProgressView().nativeProgressAppearance().frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel(L("正在读取许可证…"))
      }
    }
    .frame(
      minWidth: 480, idealWidth: 640, maxWidth: 760, minHeight: 320, idealHeight: 480,
      maxHeight: 640
    )
    .gridArea("license", inset: Space.margin)
    .gridDiagnostics("license")
    .background(KayoiTheme.background)
    .buttonStyle(FlatButtonStyle())
    .task(id: reload) {
      text = nil
      error = nil
      let url = document.resourceURL()
      do {
        let value = try await Task.detached(priority: .utility) {
          try SettingsLicense.read(at: url)
        }.value
        guard !Task.isCancelled else { return }
        text = value
      } catch {
        guard !Task.isCancelled else { return }
        self.error = HumanError.detail(error)
      }
    }
  }
}
