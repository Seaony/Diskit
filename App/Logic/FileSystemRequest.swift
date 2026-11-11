import Core
import Foundation

typealias FileSystemCompletion<Value: Sendable> = @Sendable (Result<Value, Error>) -> Void

// 系统回调可能晚于取消或超时；迟到的挂载成功仍要推出。
@MainActor final class FileSystemRequest<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Task<Void, Never>?
  private var finished = false
  private var abandoned = false
  private var nativeFinished = false
  private let sleep: @Sendable (Duration) async throws -> Void
  private let lateSuccess: @MainActor (Value) async -> Void
  private let nativeCompleted: @MainActor () -> Void

  init(
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    lateSuccess: @escaping @MainActor (Value) async -> Void = { _ in },
    nativeCompleted: @escaping @MainActor () -> Void = {}
  ) {
    self.sleep = sleep
    self.lateSuccess = lateSuccess
    self.nativeCompleted = nativeCompleted
  }

  func run(
    timeout: Duration,
    start: (@escaping FileSystemCompletion<Value>) throws -> Void
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      do { try Task.checkCancellation() } catch {
        completeNative()
        throw error
      }
      return try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          completeNative()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        do {
          try start { result in Task { @MainActor in await self.received(result) } }
          timer = Task { @MainActor in
            do { try await sleep(timeout) } catch { return }
            finish(.failure(ConnectionError.timeout))
          }
        } catch {
          finish(.failure(error))
          completeNative()
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  func received(_ result: Result<Value, Error>) async {
    if finished {
      if abandoned, case .success(let value) = result { await lateSuccess(value) }
      completeNative()
      return
    }
    finish(result)
    completeNative()
  }

  private func completeNative() {
    guard !nativeFinished else { return }
    nativeFinished = true
    nativeCompleted()
  }

  private func finish(_ result: Result<Value, Error>) {
    guard let continuation else { return }
    finished = true
    if case .failure = result { abandoned = true }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}
