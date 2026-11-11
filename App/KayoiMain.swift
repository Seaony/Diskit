import AppKit
import Core
import DevToolSupport
import Foundation
import SwiftUI

@main enum KayoiMain {
  @MainActor static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    // 命令行先分流，不创建面板、发现器或 AppModel。
    if arguments.first == "--dev-tool" {
      do {
        try await CLIRunner.run(Array(arguments.dropFirst()))
        exit(0)
      } catch {
        try? FileHandle.standardError.write(
          contentsOf: Data((CLIOutput.errorMessage(error) + "\n").utf8))
        exit(error is CancellationError ? 130 : 1)
      }
    }
    if !arguments.contains("--fskit-spike"), !RuntimeOptions.current.isDemo {
      do {
        try SharedStorageMigration.run()
      } catch {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        let alert = NSAlert()
        alert.messageText = L("无法迁移数据")
        alert.informativeText = error.localizedDescription
        alert.runModal()
        exit(1)
      }
    }
    KayoiApp.main()
  }
}
