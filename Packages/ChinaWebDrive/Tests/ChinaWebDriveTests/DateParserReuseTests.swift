import Foundation
import Testing

@testable import ChinaWebDrive

@Test func chinaSharedDateParsersKeepStrictCompactAndTimezoneRules() async {
  let samples: [(String, TimeInterval)] = [
    ("2026-11-04 15:30:00", 1_793_777_400), ("20261104153000", 1_793_777_400),
    ("20260230153000", 0), ("2026-11-04T15:30:00", 1_793_777_400),
    ("2026-11-04T07:30:00Z", 1_793_777_400), ("2026-11-04T07:30:00.125Z", 1_793_777_400.125),
    ("1793777400000", 1_793_777_400), ("1793777400", 1_793_777_400), ("invalid", 0),
  ]
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<16 {
      group.addTask {
        for (input, expected) in samples {
          #expect(ChinaWebSupport.parseDate(input).timeIntervalSince1970 == expected)
        }
      }
    }
  }
}
