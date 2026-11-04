import AppKit
import Foundation

@MainActor final class UnmountRequest {
  private var continuation: CheckedContinuation<Void, Error>?
  private var timer: Task<Void, Never>?
  func run(_ url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      Task.detached {
        let result = Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        await self.finish(result)
      }
      timer = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(RemoteTimeout.deviceRequest)) } catch { return }
        self.finish(.failure(ConnectionError.timeout))
      }
    }
  }
  private func finish(_ result: Result<Void, Error>) {
    guard let continuation else { return }
    if case .failure(let error) = result {
      PackageDiagnostics.failure(error, category: .core, operation: .unmount)
    }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}
