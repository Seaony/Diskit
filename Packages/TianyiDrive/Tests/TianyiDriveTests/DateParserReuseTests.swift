import Foundation
import Testing

@testable import TianyiDrive

@Test func tianyiSharedDateParsersPreserveFormatsUnderConcurrency() async {
  let samples: [(String, TimeInterval?)] = [
    ("2026-11-04 15:30:00", 1_793_777_400), ("2026-11-04", 1_793_721_600),
    ("2026-11-04T07:30:00Z", 1_793_777_400),
    ("Nov 4, 2026 3:30:00 PM +0800", 1_793_777_400),
    ("Nov 4, 2026, 3:30:00\u{202f}PM +0800", 1_793_777_400),
    ("Nov 4, 2026 3:30:00\u{00a0}PM", 1_793_777_400),
    ("Nov 4, 2026, 3:30:00 PM", 1_793_777_400), ("invalid", nil),
  ]
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<16 {
      group.addTask {
        for (input, expected) in samples {
          #expect(TianyiDate.parse(input)?.timeIntervalSince1970 == expected)
        }
      }
    }
  }
}
