import Core
import Foundation

final class ADBOperationDeadline {
  private let interval: TimeInterval
  private let now: @Sendable () -> ContinuousClock.Instant
  let isTransfer: Bool
  private var deadline: ContinuousClock.Instant

  init(
    timeout: TimeInterval, isTransfer: Bool = false,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
  ) {
    self.now = now
    interval = timeout
    self.isTransfer = isTransfer
    deadline = now().advanced(by: .seconds(timeout))
  }

  func remaining() throws -> TimeInterval {
    let remaining = now().duration(to: deadline)
    let seconds =
      Double(remaining.components.seconds)
      + Double(remaining.components.attoseconds) / 1e18
    guard seconds > 0 else { throw RemoteError.posix(ETIMEDOUT) }
    return seconds
  }

  func transferred(_ count: Int) {
    if isTransfer, count > 0, now() < deadline {
      deadline = now().advanced(by: .seconds(interval))
    }
  }
}
