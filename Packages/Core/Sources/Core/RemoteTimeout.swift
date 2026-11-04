import Foundation

public enum RemoteTimeout {
  public static let deviceRequest: TimeInterval = 15
  public static let cloudRequest: TimeInterval = 30
  public static let transferIdle: TimeInterval = 60

  public static func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
    let remaining = ContinuousClock.now.duration(to: deadline)
    let seconds = Double(remaining.components.seconds)
      + Double(remaining.components.attoseconds) / 1e18
    guard seconds > 0 else { throw RemoteError.posix(ETIMEDOUT) }
    return seconds
  }
}
