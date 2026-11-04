import Foundation
import Testing

@testable import Core

@Test(arguments: [
  "2026-01-02T03:04:05.123Z", "2026-01-02T03:04:05.123+00:00", "2026-01-02T03:04:05.123",
])
func remoteTimestampKeepsFractionAndUsesUTCByDefault(_ input: String) throws {
  let date = try #require(RemoteTimestamp.parse(input))
  #expect(abs(date.timeIntervalSince1970 - 1_767_323_045.123) < 0.00001)
}

@Test func remoteTimestampPreservesExplicitZoneAndRejectsInvalidInput() throws {
  let zone = TimeZone(secondsFromGMT: 28_800)!
  let value = try #require(RemoteTimestamp.parse("2026-01-02T03:04:05.123", assumedTimeZone: zone))
  #expect(abs(value.timeIntervalSince1970 - 1_767_294_245.123) < 0.00001)
  #expect(
    RemoteTimestamp.parse("2026-01-02T03:04:05Z", assumedTimeZone: zone)?.timeIntervalSince1970
      == 1_767_323_045)
  #expect(
    RemoteTimestamp.parse("2026-01-02T03:04:05", assumedTimeZone: zone)?.timeIntervalSince1970
      == 1_767_294_245)
  #expect(RemoteTimestamp.parse(nil) == nil)
  #expect(RemoteTimestamp.parse("not a date") == nil)
}
