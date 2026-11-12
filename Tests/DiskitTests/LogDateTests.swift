import Foundation
import Testing

@Test func logFilenameUsesLocalCalendarDay() throws {
  let date = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:30:00Z"))
  #expect(LogDate.filename(for: date, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!) == "2025-12-31.log")
  #expect(LogDate.filename(for: date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2026-01-01.log")
  #expect(LogDate.filename(for: date, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-01-01.log")
  let evening = try #require(ISO8601DateFormatter().date(from: "2026-06-01T18:00:00Z"))
  #expect(LogDate.filename(for: evening, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "2026-06-02.log")
}
