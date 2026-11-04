import Foundation
import Synchronization

public actor HTTPConcurrencyLimit {
  private struct WeakLimit: Sendable { weak var value: HTTPConcurrencyLimit? }
  private static let sharedLimits = Mutex<[String: WeakLimit]>([:])
  private var active = 0
  private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
  private let clock: DeadlineClock
  private var queueObserver: (@Sendable (Int) -> Void)?

  public init() { clock = .continuous }
  init(clock: DeadlineClock) { self.clock = clock }

  func observeQueue(_ observer: @escaping @Sendable (Int) -> Void) {
    queueObserver = observer
    observer(waiting.count)
  }

  public static func shared(for account: String) -> HTTPConcurrencyLimit {
    sharedLimits.withLock { limits in
      if let existing = limits[account]?.value { return existing }
      limits = limits.filter { $0.value.value != nil }
      let limit = HTTPConcurrencyLimit()
      limits[account] = WeakLimit(value: limit)
      return limit
    }
  }

  func acquire(
    deadline requestedDeadline: ContinuousClock.Instant? = nil
  ) async throws {
    let deadline =
      requestedDeadline ?? clock.now().advanced(by: .seconds(RemoteTimeout.cloudRequest))
    try Task.checkCancellation()
    guard clock.now() < deadline else { throw URLError(.timedOut) }
    if active < 4 {
      active += 1
      return
    }
    let id = UUID()
    let timeout = Task {
      do { try await clock.sleepUntil(deadline) } catch { return }
      expire(id)
    }
    defer { timeout.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiting.append((id, continuation))
          queueObserver?(waiting.count)
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
    if clock.now() >= deadline {
      release()
      throw URLError(.timedOut)
    }
  }

  private func expire(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
    waiting.remove(at: index).1.resume(throwing: URLError(.timedOut))
    queueObserver?(waiting.count)
  }

  private func cancel(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
    waiting.remove(at: index).1.resume(throwing: CancellationError())
    queueObserver?(waiting.count)
  }

  func release() {
    if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() }
    queueObserver?(waiting.count)
  }
}

public struct LimitedHTTPTransport: HTTPTransport {
  private let base: any HTTPTransport
  private let limit: HTTPConcurrencyLimit

  public init(_ base: any HTTPTransport, limit: HTTPConcurrencyLimit) {
    self.base = base
    self.limit = limit
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    try await limit.acquire()
    do {
      try Task.checkCancellation()
      let response = try await base.send(request)
      await limit.release()
      return response
    } catch {
      await limit.release()
      throw error
    }
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    try await limit.acquire()
    do {
      try Task.checkCancellation()
      let response = try await base.stream(request)
      let cursor = LimitedHTTPCursor(response.body, limit: limit)
      return HTTPStreamResponse(
        response: response.response,
        body: AsyncThrowingStream(unfolding: { try await cursor.next() }))
    } catch {
      await limit.release()
      throw error
    }
  }

  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    try await limit.acquire()
    do {
      try Task.checkCancellation()
      let response = try await base.upload(request)
      await limit.release()
      return response
    } catch {
      await limit.release()
      throw error
    }
  }
}

private actor LimitedHTTPCursor {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private let limit: HTTPConcurrencyLimit
  private var finished = false

  init(_ body: AsyncThrowingStream<Data, Error>, limit: HTTPConcurrencyLimit) {
    iterator = body.makeAsyncIterator()
    self.limit = limit
  }

  deinit {
    if !finished {
      let limit = limit
      Task { await limit.release() }
    }
  }

  func next() async throws -> Data? {
    if finished { return nil }
    guard var current = iterator else { throw RemoteError.protocolError }
    iterator = nil
    do {
      try Task.checkCancellation()
      let data = try await current.next(isolation: self)
      if data == nil {
        finished = true
        await limit.release()
      } else {
        iterator = current
      }
      return data
    } catch {
      finished = true
      await limit.release()
      throw error
    }
  }
}
