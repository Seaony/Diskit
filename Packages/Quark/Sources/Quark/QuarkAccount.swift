import Core
import Foundation

public struct QuarkAccount: Sendable, Equatable {
  public let userID: String
  public let nickname: String
  public let total: Int64
  public let used: Int64
  public init(userID: String, nickname: String, total: Int64, used: Int64) {
    self.userID = userID
    self.nickname = nickname
    self.total = total
    self.used = used
  }
}
