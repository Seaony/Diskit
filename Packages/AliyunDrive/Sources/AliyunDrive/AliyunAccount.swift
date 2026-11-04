import Core
import Foundation

public struct AliyunAccount: Sendable, Equatable {
  public let driveID: String
  public let userID: String
  public let nickname: String
  public let total: Int64
  public let used: Int64
  public let rootFolderID: String
  public init(
    driveID: String, userID: String, nickname: String, total: Int64, used: Int64,
    rootFolderID: String = "root"
  ) {
    self.driveID = driveID
    self.userID = userID
    self.nickname = nickname
    self.total = total
    self.used = used
    self.rootFolderID = rootFolderID
  }
}
