import AppKit
import Core
import SwiftUI

@MainActor struct PanelCommandActions {
  let canEdit: Bool
  let canDelete: Bool
  let edit: @MainActor () -> Void
  let delete: @MainActor () -> Void
}

private struct PanelCommandsKey: FocusedValueKey {
  typealias Value = PanelCommandActions
}

extension FocusedValues {
  var panelCommands: PanelCommandActions? {
    get { self[PanelCommandsKey.self] }
    set { self[PanelCommandsKey.self] = newValue }
  }
}

@MainActor struct DiskitCommands: Commands {
  let model: AppModel
  let windows: WindowCoordinator
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.panelCommands) private var panel

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button(L("关于 Diskit")) {
        windows.prepareToOpen()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
        NSApplication.shared.activate()
      }
    }
    CommandGroup(after: .appInfo) {
      Button(L("检查更新…")) { model.updates.checkForUpdates() }
        .disabled(!model.updates.canCheckForUpdates)
    }
    CommandGroup(replacing: .appSettings) {
      SettingsLink { Text(L("设置…")) }.keyboardShortcut(",", modifiers: .command)
    }
    CommandGroup(replacing: .newItem) {
      Button(L("添加位置…")) {
        model.editing = nil
        model.pairingSelection = nil
        model.forceLogin = false
        windows.prepareToOpen()
        openWindow(id: "connection")
        NSApplication.shared.activate()
      }.keyboardShortcut("n", modifiers: .command)
      Button(L("编辑…")) { panel?.edit() }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(panel?.canEdit != true)
      Button(L("删除…")) { panel?.delete() }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(panel?.canDelete != true)
    }
    CommandGroup(replacing: .undoRedo) {
      SharedUndoCommands(manager: model.undoManager, panelActive: panel != nil)
    }
    // 没有帮助页面，清掉系统默认的帮助菜单项
    CommandGroup(replacing: .help) {}
  }
}

// 面板是当前窗口时撤销面板上的排序、改名；其他窗口（编辑、搜索、网页登录）里的输入框用它们自己的撤销
private struct SharedUndoCommands: View {
  let manager: UndoManager
  let panelActive: Bool
  @State private var revision = 0

  // 其他窗口：输入框的撤销记录在当前窗口响应链的 undoManager 里
  private var responderManager: UndoManager? { NSApp.keyWindow?.firstResponder?.undoManager }

  var body: some View {
    let _ = revision
    let target = panelActive ? manager : responderManager
    Group {
      Button(target?.undoMenuItemTitle ?? manager.undoMenuTitle(forUndoActionName: "")) {
        if panelActive { manager.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
      }
      .keyboardShortcut("z", modifiers: .command)
      .disabled(target?.canUndo != true)
      Button(target?.redoMenuItemTitle ?? manager.redoMenuTitle(forUndoActionName: "")) {
        if panelActive { manager.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .disabled(target?.canRedo != true)
    }
    // 任何窗口的撤销记录变了、换了当前窗口都刷新菜单项的标题和可用状态
    .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in revision += 1 }
    .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in revision += 1 }
    .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in revision += 1 }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in revision += 1 }
  }
}
