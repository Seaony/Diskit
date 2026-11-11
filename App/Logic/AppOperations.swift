import Foundation

@MainActor final class AppOperations {
  private struct Entry {
    let task: Task<Void, Never>
    let cancel: (@MainActor () -> Void)?
    let connectionID: UUID?
  }
  private var entries: [UUID: Entry] = [:]
  private var finishing: [Task<Void, Never>] = []
  private(set) var isStopping = false

  @discardableResult
  func start(
    connectionID: UUID? = nil,
    onCancel: (@MainActor () -> Void)? = nil,
    onFinish: (@MainActor () -> Void)? = nil,
    operation: @escaping @MainActor () async -> Void
  ) -> Task<Void, Never> {
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        entries.removeValue(forKey: id)
        onFinish?()
      }
      guard !isStopping, !Task.isCancelled else { return }
      await operation()
    }
    if isStopping {
      task.cancel()
      onCancel?()
    } else {
      entries[id] = Entry(task: task, cancel: onCancel, connectionID: connectionID)
    }
    return task
  }

  func cancel(connectionID: UUID) {
    let pending = entries.values.filter { $0.connectionID == connectionID }
    for entry in pending {
      entry.task.cancel()
      entry.cancel?()
    }
  }

  func cancelAndWait(connectionID: UUID) async {
    let pending = entries.values.filter { $0.connectionID == connectionID }
    cancel(connectionID: connectionID)
    for entry in pending { await entry.task.value }
  }

  func resume() { isStopping = false }

  func finishCancellation() async {
    for task in finishing { await task.value }
    finishing.removeAll()
  }

  func cancelAll() {
    guard !isStopping else { return }
    isStopping = true
    let pending = Array(entries.values)
    entries.removeAll()
    finishing = pending.map(\.task)
    for entry in pending {
      entry.task.cancel()
      entry.cancel?()
    }
  }
}
