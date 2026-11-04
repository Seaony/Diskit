import Foundation

struct DeadlineClock: Sendable {
  let now: @Sendable () -> ContinuousClock.Instant
  let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

  static let continuous = DeadlineClock(
    now: { .now },
    sleepUntil: { try await Task.sleep(until: $0, clock: .continuous) })
}
