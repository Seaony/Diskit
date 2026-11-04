import Foundation

@MainActor protocol WebLoginAuthorizing: AnyObject {
  func authorize(
    service: WebLoginService, options: RuntimeOptions,
    validate: @escaping @MainActor (WebLoginCredentials) async throws -> Void
  ) async throws -> WebLoginCredentials
  func cancel()
}

@MainActor protocol OAuthAuthorizing: AnyObject {
  func authorize(_ url: URL) async throws -> URL
  func cancel()
}
