import AppKit
import Core

@MainActor enum ConnectionPresentationUndo {
  static func register(
    previous: Connection?, current: Connection, manager: ConnectionManager, undo: UndoManager
  ) {
    guard let previous, previous.name != current.name || previous.color != current.color else {
      return
    }
    undo.registerUndo(withTarget: manager) { [weak undo] manager in
      MainActor.assumeIsolated {
        guard let undo, let latest = manager.connections.first(where: { $0.id == previous.id })
        else { return }
        do {
          try manager.setPresentation(id: previous.id, name: previous.name, color: previous.color)
          register(previous: latest, current: previous, manager: manager, undo: undo)
        } catch { manager.reportOperationError(error) }
      }
    }
    undo.setActionName(L("修改位置名称和颜色"))
  }
}
