import Foundation

@MainActor final class MountCapacityRequest {
  private let clock: DeadlineClock
  private var continuation: CheckedContinuation<Int64?, Never>?
  private var timer: Task<Void, Never>?

  init(clock: DeadlineClock = .continuous) { self.clock = clock }

  func run(
    read: @escaping @Sendable () -> Int64?,
    completed: @escaping @MainActor @Sendable (Int64?) -> Void
  ) async -> Int64? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          completed(nil)
          continuation.resume(returning: nil)
          return
        }
        self.continuation = continuation
        let deadline = clock.now().advanced(by: .seconds(RemoteTimeout.deviceRequest))
        timer = Task { @MainActor in
          do { try await clock.sleepUntil(deadline) } catch { return }
          finish(nil)
        }
        Task.detached(priority: .utility) {
          let value = read()
          await MainActor.run {
            completed(value)
            self.finish(value)
          }
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(nil) }
    }
  }

  private func finish(_ value: Int64?) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(returning: value)
  }

  nonisolated static func bytes(blocks: UInt64, blockSize: UInt32) -> Int64? {
    guard blockSize > 0, let count = Int64(exactly: blocks) else { return nil }
    let result = count.multipliedReportingOverflow(by: Int64(blockSize))
    return result.overflow ? nil : result.partialValue
  }
}
