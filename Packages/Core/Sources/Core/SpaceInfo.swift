import Foundation

public struct SpaceInfo: Sendable, Equatable {
  public let total: Int64?
  public let used: Int64?
  public let available: Int64?
  public init(total: Int64?, used: Int64?, available: Int64? = nil) {
    let total = total.flatMap { $0 >= 0 ? $0 : nil }
    let used = used.flatMap { $0 >= 0 ? $0 : nil }
    self.total = total
    self.used = used
    if let available {
      self.available = available >= 0 && (total.map { available <= $0 } ?? true) ? available : nil
    } else if let total, let used {
      self.available = used <= total ? total - used : nil
    } else {
      self.available = nil
    }
  }
}
