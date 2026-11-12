import AppKit
import Core
import DevToolSupport
import Foundation
import SwiftUI

@main enum DiskitMain {
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
    if !RuntimeOptions.current.isDemo {
      if let error = RuntimeStorage.prepareForApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        let alert = NSAlert()
        alert.messageText = L("无法迁移数据")
        alert.informativeText = LF(
          "旧数据已保留。本次继续使用旧存储，下次启动重试。\n%@\n详情见“控制台”中的 Diskit 日志。",
          error.localizedDescription)
        alert.runModal()
      }
    }
    DiskitApp.main()
  }
}
