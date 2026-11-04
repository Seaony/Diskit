import Foundation

public enum RemoteTimestamp {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let whole = Date.ISO8601FormatStyle()

  public static func parse(_ value: String?, assumedTimeZone: TimeZone = .gmt) -> Date? {
    guard let value else { return nil }
    if let date = try? fractional.parse(value) { return date }
    if let date = try? whole.parse(value) { return date }
    // 缺少时区时使用服务约定，不能随用户系统时区变化。
    let localFractional = Date.ISO8601FormatStyle(
      includingFractionalSeconds: true, timeZone: assumedTimeZone
    )
    .year().month().day().time(includingFractionalSeconds: true)
    if let date = try? localFractional.parse(value) { return date }
    let localWhole = Date.ISO8601FormatStyle(timeZone: assumedTimeZone)
      .year().month().day().time(includingFractionalSeconds: false)
    return try? localWhole.parse(value)
  }
}
