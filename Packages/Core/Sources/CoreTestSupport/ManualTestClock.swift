import Foundation
import Synchronization

public final class ManualTestClock: Clock, Sendable {
  public typealias Instant = ContinuousClock.Instant
  public typealias Duration = Swift.Duration
  public var minimumResolution: Duration { .nanoseconds(1) }
  public init() {}
  private struct Sleeper {
    let until: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, Error>
  }
  private struct State {
    var now = ContinuousClock.now
    var sleepers: [UUID: Sleeper] = [:]
    var sleepRequests = 0
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  }
  private let state = Mutex(State())

  public var now: ContinuousClock.Instant { state.withLock { $0.now } }
  public var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

  public func advance(by duration: Duration) {
    let ready = state.withLock { value in
      value.now = value.now.advanced(by: duration)
      let ready = value.sleepers.filter { $0.value.until <= value.now }
      for id in ready.keys { value.sleepers.removeValue(forKey: id) }
      return ready.values.map(\.continuation)
    }
    for continuation in ready { continuation.resume() }
  }

  public func waitForSleepRequests(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { value in
        if value.sleepRequests >= count { return true }
        value.observers.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  public func sleep(until instant: Instant, tolerance: Duration? = nil) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let outcome = state.withLock {
          value -> (Result<Void, Error>?, [CheckedContinuation<Void, Never>]) in
          let result: Result<Void, Error>?
          if Task.isCancelled {
            result = .failure(CancellationError())
          } else if instant <= value.now {
            result = .success(())
          } else {
            value.sleepers[id] = Sleeper(until: instant, continuation: continuation)
            result = nil
          }
          value.sleepRequests += 1
          let ready = value.observers.filter { $0.0 <= value.sleepRequests }.map(\.1)
          value.observers.removeAll { $0.0 <= value.sleepRequests }
          return (result, ready)
        }
        if let result = outcome.0 { continuation.resume(with: result) }
        for observer in outcome.1 { observer.resume() }
      }
    } onCancel: {
      self.state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(
        throwing: CancellationError())
    }
    try Task.checkCancellation()
  }
}
