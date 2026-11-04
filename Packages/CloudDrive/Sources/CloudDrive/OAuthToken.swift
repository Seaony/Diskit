import Foundation

public struct OAuthToken: Codable, Sendable, Equatable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date
  public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}
