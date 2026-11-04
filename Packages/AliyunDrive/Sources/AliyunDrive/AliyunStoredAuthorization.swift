import Core
import Foundation

struct AliyunStoredAuthorization: Codable, Sendable {
  var accessToken: String
  var refreshToken: String
  var expiresAt: TimeInterval
  var configuration: AliyunConfiguration
  var invalidated = false
}
