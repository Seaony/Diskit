import Foundation
import Testing

@testable import LanzouDrive

@Test func lanzouSharedDateParsersPreserveAbsoluteAndRelativeDates() async {
  let reference = Date(timeIntervalSince1970: 2_000_000_000)
  let samples: [(String, TimeInterval)] = [
    ("2026-11-04 15:30:00", 1_793_777_400), ("2026-11-04", 1_793_721_600),
    ("2026/11/04 15:30:00", 1_793_777_400), ("2026/11/04", 1_793_721_600),
    ("2026-11-04T07:30:00Z", 1_793_777_400), ("昨天", 2_000_000_000 - 86_400),
    ("前天", 2_000_000_000 - 172_800), ("3分钟前", 2_000_000_000 - 180), ("invalid", 0),
  ]
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<16 {
      group.addTask {
        for (input, expected) in samples {
          #expect(
            LanzouValues.parseDate(input, relativeTo: reference).timeIntervalSince1970 == expected)
        }
      }
    }
  }
}
