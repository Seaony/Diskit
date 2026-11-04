import Foundation

public protocol OAuthProfileProviding: Sendable {
  func profile() async throws -> OAuthProfile
}
