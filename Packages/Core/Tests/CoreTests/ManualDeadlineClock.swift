import CoreTestSupport

@testable import Core

extension ManualTestClock {
  var deadlineClock: DeadlineClock {
    DeadlineClock(now: { self.now }, sleepUntil: { try await self.sleep(until: $0) })
  }
}
