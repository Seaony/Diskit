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

@MainActor struct KayoiCommands: Commands {
  let model: AppModel
  let windows: WindowCoordinator
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.panelCommands) private var panel

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button(L("关于 Kayoi")) {
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
      SharedUndoCommands(manager: model.undoManager)
    }
    CommandGroup(replacing: .help) {
      Button(L("Kayoi 帮助")) {
        windows.prepareToOpen()
        openWindow(id: "help")
        NSApplication.shared.activate()
      }.keyboardShortcut("?", modifiers: .command)
    }
  }
}

private struct SharedUndoCommands: View {
  let manager: UndoManager
  @State private var revision = 0

  var body: some View {
    let _ = revision
    Group {
      Button(manager.undoMenuItemTitle) { manager.undo() }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!manager.canUndo)
      Button(manager.redoMenuItemTitle) { manager.redo() }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!manager.canRedo)
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: .NSUndoManagerDidCloseUndoGroup, object: manager)
    ) { _ in revision += 1 }
    .onReceive(
      NotificationCenter.default.publisher(
        for: .NSUndoManagerDidUndoChange, object: manager)
    ) { _ in revision += 1 }
    .onReceive(
      NotificationCenter.default.publisher(
        for: .NSUndoManagerDidRedoChange, object: manager)
    ) { _ in revision += 1 }
  }
}
