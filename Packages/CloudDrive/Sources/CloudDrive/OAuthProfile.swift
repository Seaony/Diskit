import Foundation

public struct OAuthProfile: Sendable, Equatable {
  public let userID: String
  public let nickname: String
  public let avatarURL: String?
  public init(userID: String, nickname: String, avatarURL: String? = nil) {
    self.userID = userID
    self.nickname = nickname
    self.avatarURL = avatarURL
  }
}
