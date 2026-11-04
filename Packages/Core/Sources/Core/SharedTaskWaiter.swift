import Synchronization

public enum SharedTaskWaiter {
  public static func value<Value: Sendable>(of task: Task<Value, Error>) async throws -> Value {
    let waiter = SharedTaskContinuation<Value>()
    let value = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        waiter.install(continuation)
        Task { waiter.finish(await task.result) }
      }
    } onCancel: {
      // 只结束当前等待，刷新和持久化仍由共享任务完成。
      waiter.finish(.failure(CancellationError()))
    }
    try Task.checkCancellation()
    return value
  }
}

private final class SharedTaskContinuation<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, Error>?
    var continuation: CheckedContinuation<Value, Error>?
  }
  private let state = Mutex(State())

  func install(_ continuation: CheckedContinuation<Value, Error>) {
    let result = state.withLock { state -> Result<Value, Error>? in
      if let result = state.result { return result }
      state.continuation = continuation
      return nil
    }
    if let result { continuation.resume(with: result) }
  }

  func finish(_ result: Result<Value, Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<Value, Error>? in
      guard case nil = state.result else { return nil }
      state.result = result
      defer { state.continuation = nil }
      return state.continuation
    }
    continuation?.resume(with: result)
  }
}
