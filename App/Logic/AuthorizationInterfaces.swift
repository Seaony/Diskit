import Foundation


@MainActor protocol OAuthAuthorizing: AnyObject {
  func authorize(_ url: URL) async throws -> URL
  func cancel()
}
