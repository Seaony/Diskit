import Foundation
import Synchronization

public final class TestEvent: Sendable {
  private struct State {
    var signaled = false
    var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  }
  private let state = Mutex(State())
  public init() {}
  public var isSignaled: Bool { state.withLock { $0.signaled } }

  public func signal() {
    let waiters = state.withLock { value in
      value.signaled = true
      let waiters = Array(value.waiters.values)
      value.waiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  public func wait() async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let result = state.withLock { value -> Result<Void, Error>? in
          if Task.isCancelled { return .failure(CancellationError()) }
          if value.signaled { return .success(()) }
          value.waiters[id] = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(
        throwing: CancellationError())
    }
    try Task.checkCancellation()
  }
}
