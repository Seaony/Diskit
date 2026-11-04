import Foundation
import Synchronization

public final class HTTPProgressDeadline: Sendable {
  private let interval: Duration
  private let clock: DeadlineClock
  private let deadline: Mutex<ContinuousClock.Instant>

  public convenience init(interval: Duration) {
    self.init(interval: interval, clock: .continuous)
  }

  init(interval: Duration, clock: DeadlineClock) {
    self.interval = interval
    self.clock = clock
    deadline = Mutex(clock.now().advanced(by: interval))
  }

  public func recordProgress() {
    deadline.withLock {
      let now = clock.now()
      if now < $0 { $0 = now.advanced(by: interval) }
    }
  }

  public func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await self.wait()
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw URLError(.cancelled) }
      return value
    }
  }

  func wait() async throws {
    while true {
      let next = deadline.withLock { $0 }
      try await clock.sleepUntil(next)
      if deadline.withLock({ clock.now() >= $0 }) { throw URLError(.timedOut) }
    }
  }
}
