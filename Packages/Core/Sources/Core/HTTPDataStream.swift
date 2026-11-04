import Foundation
import Synchronization

final class HTTPDataStream: @unchecked Sendable {
  static let chunkBytes = 64 * 1024
  static let highWaterBytes = 1024 * 1024
  static let lowWaterBytes = 256 * 1024
  static let maximumBufferedBytes = 4 * 1024 * 1024

  struct Statistics: Sendable {
    let bufferedChunks: Int
    let bufferedBytes: Int
    let peakBufferedBytes: Int
    let receivedBytes: Int
    let callbacks: Int
    let pauses: Int
    let resumes: Int
  }

  private struct State {
    var task: URLSessionDataTask?
    var headerDeadline: ContinuousClock.Instant?
    var headers: Result<HTTPResponse, Error>?
    var headerWaiter: CheckedContinuation<HTTPResponse, Error>?
    var chunks: [Data] = []
    var head = 0
    var bufferedBytes = 0
    var peakBufferedBytes = 0
    var receivedBytes = 0
    var callbacks = 0
    var pauses = 0
    var resumes = 0
    var nextWaiter: CheckedContinuation<Data?, Error>?
    var end: Result<Void, Error>?
    var pausedAt: ContinuousClock.Instant?
    var idleDeadline: ContinuousClock.Instant?
    var idleTimerID: UUID?
    var headerTimer: Task<Void, Never>?
    var idleTimer: Task<Void, Never>?
  }

  private let state = Mutex(State())
  private let control = DispatchQueue(label: "com.seaony.Kayoi.http-stream-control")
  private let clock: DeadlineClock

  init(clock: DeadlineClock = .continuous) { self.clock = clock }

  func start(session: URLSession, request: URLRequest, cookieDomain: String?) {
    let task = session.dataTask(with: request)
    task.delegate = HTTPDataStreamDelegate(stream: self, cookieDomain: cookieDomain)
    let deadline = clock.now().advanced(by: .seconds(RemoteTimeout.cloudRequest))
    let clock = clock
    state.withLock { state in
      state.task = task
      state.headerDeadline = deadline
      state.headerTimer = Task { [weak self] in
        do { try await clock.sleepUntil(deadline) } catch { return }
        self?.expireHeaders()
      }
      control.async { task.resume() }
    }
  }

  func response() async throws -> HTTPResponse {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let result = state.withLock { state -> Result<HTTPResponse, Error>? in
          if let headers = state.headers { return headers }
          state.headerWaiter = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func receive(_ response: URLResponse) -> Bool {
    let metadata: HTTPResponse
    do { metadata = try URLSessionHTTPTransport.response(response, data: Data()) }
    catch { fail(error); return false }
    var expired = false
    let result = state.withLock { state -> (Bool, CheckedContinuation<HTTPResponse, Error>?) in
      guard state.end == nil, state.headers == nil else { return (false, nil) }
      if let deadline = state.headerDeadline, clock.now() >= deadline {
        expired = true
        return (false, nil)
      }
      state.headers = .success(metadata)
      state.headerTimer?.cancel()
      state.headerTimer = nil
      state.idleDeadline = clock.now().advanced(by: .seconds(RemoteTimeout.transferIdle))
      armIdleTimer(&state)
      let waiter = state.headerWaiter
      state.headerWaiter = nil
      return (true, waiter)
    }
    if expired { fail(URLError(.timedOut)); return false }
    result.1?.resume(returning: metadata)
    return result.0
  }

  func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    var failure: Error?
    let delivery = state.withLock { state -> (CheckedContinuation<Data?, Error>, Data)? in
      guard state.end == nil else { return nil }
      guard data.count <= Self.maximumBufferedBytes - state.bufferedBytes else {
        failure = POSIXError(.ENOBUFS)
        return nil
      }
      let now = clock.now()
      if state.pausedAt == nil, let deadline = state.idleDeadline, now >= deadline {
        failure = URLError(.timedOut)
        return nil
      }
      state.callbacks += 1
      state.receivedBytes += data.count
      state.idleDeadline = now.advanced(by: .seconds(RemoteTimeout.transferIdle))
      if state.pausedAt != nil { state.pausedAt = now }
      var delivery: (CheckedContinuation<Data?, Error>, Data)?
      var offset = 0
      while offset < data.count {
        if state.head < state.chunks.count,
          let last = state.chunks.indices.last, state.chunks[last].count < Self.chunkBytes
        {
          let count = min(Self.chunkBytes - state.chunks[last].count, data.count - offset)
          state.chunks[last].append(data.subdata(in: offset..<(offset + count)))
          state.bufferedBytes += count
          offset += count
          continue
        }
        let end = min(offset + Self.chunkBytes, data.count)
        let chunk = data.subdata(in: offset..<end)
        offset = end
        if let waiter = state.nextWaiter {
          state.nextWaiter = nil
          delivery = (waiter, chunk)
        } else {
          state.chunks.append(chunk)
          state.bufferedBytes += chunk.count
        }
      }
      state.peakBufferedBytes = max(state.peakBufferedBytes, state.bufferedBytes)
      if state.bufferedBytes >= Self.highWaterBytes, state.pausedAt == nil, let task = state.task {
        state.pausedAt = now
        state.pauses += 1
        state.idleTimer?.cancel()
        state.idleTimer = nil
        state.idleTimerID = nil
        // 控制动作按同一锁内入队，不能让恢复先于对应的暂停执行。
        control.async { task.suspend() }
      }
      return delivery
    }
    if let failure { fail(failure); return }
    if let (waiter, chunk) = delivery { waiter.resume(returning: chunk) }
  }

  func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let result = state.withLock { state -> Result<Data?, Error>? in
          if state.head < state.chunks.count {
            let chunk = state.chunks[state.head]
            state.chunks[state.head] = Data()
            state.head += 1
            state.bufferedBytes -= chunk.count
            if state.head == state.chunks.count {
              state.chunks.removeAll(keepingCapacity: true)
              state.head = 0
            } else if state.head >= 64 {
              state.chunks.removeFirst(state.head)
              state.head = 0
            }
            resumeIfReady(&state)
            return .success(chunk)
          }
          if let end = state.end { return end.map { nil } }
          guard state.nextWaiter == nil else { return .failure(RemoteError.protocolError) }
          state.nextWaiter = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func finish(_ error: Error?) {
    let waiting = state.withLock { state -> (CheckedContinuation<HTTPResponse, Error>?, CheckedContinuation<Data?, Error>?) in
      guard state.end == nil else { return (nil, nil) }
      state.end = error.map { .failure($0) } ?? .success(())
      stopTimers(&state)
      state.task = nil
      let header = state.headerWaiter
      state.headerWaiter = nil
      if state.headers == nil { state.headers = .failure(error ?? URLError(.badServerResponse)) }
      let body = state.nextWaiter
      state.nextWaiter = nil
      return (header, body)
    }
    waiting.0?.resume(throwing: error ?? URLError(.badServerResponse))
    if let error { waiting.1?.resume(throwing: error) }
    else { waiting.1?.resume(returning: nil) }
  }

  func cancel() { fail(CancellationError(), discardBuffered: true) }
  private func fail(_ error: Error, discardBuffered: Bool = false, when predicate: (State) -> Bool = { _ in true }) {
    let waiting = state.withLock { state -> (CheckedContinuation<HTTPResponse, Error>?, CheckedContinuation<Data?, Error>?) in
      guard predicate(state) else { return (nil, nil) }
      if discardBuffered {
        state.chunks.removeAll()
        state.head = 0
        state.bufferedBytes = 0
      }
      guard state.end == nil else { return (nil, nil) }
      state.end = .failure(error)
      if state.headers == nil { state.headers = .failure(error) }
      stopTimers(&state)
      if let task = state.task { control.async { task.cancel() } }
      state.task = nil
      let waiting = (state.headerWaiter, state.nextWaiter)
      state.headerWaiter = nil
      state.nextWaiter = nil
      return waiting
    }
    waiting.0?.resume(throwing: error)
    waiting.1?.resume(throwing: error)
  }
  private func expireHeaders() {
    fail(URLError(.timedOut), when: { $0.headers == nil })
  }
  private func armIdleTimer(_ state: inout State) {
    guard state.idleTimer == nil, state.end == nil, state.pausedAt == nil else { return }
    let id = UUID()
    state.idleTimerID = id
    let clock = clock
    state.idleTimer = Task { [weak self] in
      while let deadline = self?.idleWake(id) {
        do { try await clock.sleepUntil(deadline) } catch { return }
        self?.expireIdle(id)
      }
    }
  }
  private func idleWake(_ id: UUID) -> ContinuousClock.Instant? {
    state.withLock { state in
      guard state.idleTimerID == id, state.end == nil, state.pausedAt == nil else { return nil }
      return state.idleDeadline
    }
  }
  private func expireIdle(_ id: UUID) {
    fail(URLError(.timedOut), when: { state in
      guard state.idleTimerID == id, state.pausedAt == nil,
        let deadline = state.idleDeadline else { return false }
      return clock.now() >= deadline
    })
  }
  private func resumeIfReady(_ state: inout State) {
    guard let pausedAt = state.pausedAt, state.bufferedBytes <= Self.lowWaterBytes,
      state.end == nil, let task = state.task else { return }
    let now = clock.now()
    if let deadline = state.idleDeadline {
      state.idleDeadline = deadline.advanced(by: pausedAt.duration(to: now))
    }
    state.pausedAt = nil
    state.resumes += 1
    armIdleTimer(&state)
    control.async { task.resume() }
  }
  private func stopTimers(_ state: inout State) {
    state.headerTimer?.cancel()
    state.idleTimer?.cancel()
    state.headerTimer = nil
    state.idleTimer = nil
    state.idleTimerID = nil
  }

  var statistics: Statistics {
    state.withLock {
      Statistics(bufferedChunks: $0.chunks.count - $0.head, bufferedBytes: $0.bufferedBytes, peakBufferedBytes: $0.peakBufferedBytes,
        receivedBytes: $0.receivedBytes, callbacks: $0.callbacks, pauses: $0.pauses, resumes: $0.resumes)
    }
  }

  deinit {
    state.withLock { state in
      state.headerTimer?.cancel()
      state.idleTimer?.cancel()
      if let task = state.task { control.async { task.cancel() } }
    }
  }
}
