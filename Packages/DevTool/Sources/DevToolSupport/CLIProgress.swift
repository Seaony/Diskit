import Foundation
import Synchronization

final class CLIProgress: Sendable {
  private let start = ContinuousClock.now
  private let last = Mutex<ContinuousClock.Instant?>(nil)
  private let output: @Sendable (String) -> Void
  init(output: @escaping @Sendable (String) -> Void) { self.output = output }
  func report(_ bytes: Int64, total: Int64?) {
    let now = ContinuousClock.now
    let emit = last.withLock { last in
      guard bytes == total || last == nil || last!.duration(to: now) >= .milliseconds(500) else {
        return false
      }
      last = now
      return true
    }
    guard emit else { return }
    let elapsed = start.duration(to: now).components
    let seconds = max(0.001, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    output(
      "\(bytes) / \(total.map(String.init) ?? "?") bytes · \(String(format: "%.2f", Double(bytes) / seconds / 1_000_000)) MB/s"
    )
  }
}
