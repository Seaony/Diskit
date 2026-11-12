import Foundation

// 同一队列排列提交和取消，完成回调前保留传输缓冲区。
final class USBIORequest: @unchecked Sendable {
  typealias Completion = @Sendable (Result<Int, Error>) -> Void
  private let queue = DispatchQueue(label: "com.seaony.Diskit.USBRequest")
  private let enqueue: @Sendable (@escaping Completion) throws -> Void
  private let abort: @Sendable () -> Void
  private var continuation: CheckedContinuation<Int, Error>?
  private var cancelled = false
  private var started = false
  private var finished = false

  init(
    enqueue: @escaping @Sendable (@escaping Completion) throws -> Void,
    abort: @escaping @Sendable () -> Void
  ) {
    self.enqueue = enqueue
    self.abort = abort
  }

  func run() async throws -> Int {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          self.continuation = continuation
          if self.cancelled {
            self.finish(.failure(CancellationError()))
            return
          }
          self.started = true
          do {
            try self.enqueue { result in self.queue.async { self.finish(result) } }
          } catch { self.finish(.failure(error)) }
        }
      }
    } onCancel: {
      self.queue.async {
        guard !self.finished else { return }
        self.cancelled = true
        if self.started { self.abort() }
      }
    }
  }

  private func finish(_ result: Result<Int, Error>) {
    guard !finished, let continuation else { return }
    finished = true
    self.continuation = nil
    continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
  }

}
