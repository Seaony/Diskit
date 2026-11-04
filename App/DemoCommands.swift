import Core
import SwiftUI

@MainActor struct DemoCommands: Commands {
  let model: AppModel
  var body: some Commands {
    if model.options.isDemo {
      CommandMenu(L("演示")) {
        Button(L("空白表单")) { model.selectDemoEditorState(.blank) }
          .keyboardShortcut("1", modifiers: [.control, .option])
        Button(L("填写中")) { model.selectDemoEditorState(.filled) }
          .keyboardShortcut("2", modifiers: [.control, .option])
        Button(L("连接错误")) { model.selectDemoEditorState(.error) }
          .keyboardShortcut("3", modifiers: [.control, .option])
        Button(L("测试中")) { model.selectDemoEditorState(.testing) }
          .keyboardShortcut("4", modifiers: [.control, .option])
        Button(L("连接测试成功")) { model.selectDemoEditorState(.success) }
          .keyboardShortcut("5", modifiers: [.control, .option])
        Divider()
        Button(L("浅色外观")) { model.selectDemoAppearance("light") }
          .keyboardShortcut("l", modifiers: [.control, .option])
        Button(L("深色外观")) { model.selectDemoAppearance("dark") }
          .keyboardShortcut("d", modifiers: [.control, .option])
      }
    }
  }
}
