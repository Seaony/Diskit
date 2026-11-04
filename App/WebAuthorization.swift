import AppKit
import AuthenticationServices
import Core
import Foundation

@MainActor final class WebAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
  private let window: NSWindow
  private var session: ASWebAuthenticationSession?
  private var continuation: CheckedContinuation<URL, Error>?
  init(window: NSWindow) { self.window = window }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window
  }
  func authorize(_ url: URL) async throws -> URL {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<URL, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        let callbackScheme = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "redirect_uri" })?.value
          .flatMap(URL.init(string:))?.scheme
        guard let callbackScheme else {
          self.finish(.failure(URLError(.badURL)))
          return
        }
        let session = ASWebAuthenticationSession(
          url: url, callbackURLScheme: callbackScheme
        ) {
          url, error in
          Task { @MainActor in
            if let error {
              if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                self.finish(.failure(CancellationError()))
              } else {
                self.finish(.failure(error))
              }
            } else if let url {
              self.finish(.success(url))
            } else {
              self.finish(.failure(URLError(.badURL)))
            }
          }
        }
        self.session = session
        session.presentationContextProvider = self
        if !session.start() { finish(.failure(URLError(.cannotConnectToHost))) }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  func cancel() {
    session?.cancel()
    finish(.failure(CancellationError()))
  }
  private func finish(_ result: Result<URL, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    session = nil
    continuation.resume(with: result)
  }
}
