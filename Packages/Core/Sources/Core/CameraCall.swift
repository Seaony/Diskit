import Foundation

@MainActor
public final class CameraCall<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Task<Void, Never>?
  private var deadline: ContinuousClock.Instant?
  private let now: @Sendable () -> ContinuousClock.Instant
  private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

  public convenience init() {
    self.init(now: { .now }, sleepUntil: { try await Task.sleep(until: $0, clock: .continuous) })
  }

  init(
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void
  ) {
    self.now = now
    self.sleepUntil = sleepUntil
  }

  public func run(
    seconds: Double, _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
  )
    async throws -> Value
  {
    try await run(until: now().advanced(by: .seconds(seconds)), start)
  }

  public func run(
    until deadline: ContinuousClock.Instant,
    _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
  ) async throws -> Value {
    try Task.checkCancellation()
    guard now() < deadline else { throw RemoteError.posix(ETIMEDOUT) }
    self.deadline = deadline
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        timer = Task { @MainActor in
          do {
            try await sleepUntil(deadline)
          } catch {
            return
          }
          self.finish(.failure(RemoteError.posix(ETIMEDOUT)))
        }
        start { result in
          Task { @MainActor in
            self.finish(result)
          }
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.finish(.failure(CancellationError()))
      }
    }
  }

  private func finish(_ result: Result<Value, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    if case .success = result, let deadline, now() >= deadline {
      continuation.resume(throwing: RemoteError.posix(ETIMEDOUT))
    } else {
      continuation.resume(with: result)
    }
    deadline = nil
  }
}
