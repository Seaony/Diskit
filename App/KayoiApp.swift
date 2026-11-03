import Core
import SwiftUI

@main
struct KayoiApp: App {
  var body: some Scene {
    MenuBarExtra("Kayoi", systemImage: "externaldrive") {
      VStack(alignment: .leading, spacing: 16) {
        Text("Kayoi").font(.title.bold())
        Text("尚未添加位置").foregroundStyle(.secondary)
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
      }.padding().frame(width: 380)
    }.menuBarExtraStyle(.window)
  }
}
