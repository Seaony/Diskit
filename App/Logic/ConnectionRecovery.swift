import Foundation

@MainActor final class ConnectionRecovery {
  private let operations: AppOperations
  private let refresh: @MainActor () -> Void
  private let recover: @MainActor () async -> Void
  private var task: Task<Void, Never>?
  private var pending = false
  private var sleeping = false
  private var online: Bool?
  private var stopped = false

  init(
    operations: AppOperations,
    refresh: @escaping @MainActor () -> Void,
    recover: @escaping @MainActor () async -> Void
  ) {
    self.operations = operations
    self.refresh = refresh
    self.recover = recover
  }

  func start() { requestRecovery() }

  func networkChanged(available: Bool) {
    guard !stopped else { return }
    online = available
    refresh()
    if available {
      requestRecovery()
    } else {
      pending = false
      task?.cancel()
    }
  }

  func willSleep() {
    guard !stopped else { return }
    sleeping = true
    pending = false
    task?.cancel()
  }

  func didWake() {
    guard !stopped else { return }
    sleeping = false
    refresh()
    requestRecovery()
  }

  func stop() {
    stopped = true
    pending = false
    task?.cancel()
  }

  private var canRecover: Bool { !stopped && !sleeping && online != false }

  private func requestRecovery() {
    guard canRecover else { return }
    pending = true
    startIfNeeded()
  }

  private func startIfNeeded() {
    guard task == nil, canRecover, !operations.isStopping else { return }
    task = operations.start(onFinish: { [weak self] in
      guard let self else { return }
      task = nil
      if pending && canRecover { startIfNeeded() }
    }) { [weak self] in
      guard let self else { return }
      while pending && canRecover && !Task.isCancelled {
        pending = false
        await recover()
      }
    }
  }
}
