import Core
import Foundation
import Network

protocol ADBNetworkIO: Sendable {
  func start(_ handler: @escaping @Sendable (NWConnection.State) -> Void)
  func stopObservingState()
  func receive(count: Int, completion: @escaping @Sendable (Data?, NWError?) -> Void)
  func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void)
  func exportedSecret() -> Data?
  func cancel()
}

enum ADBStartTLSProtocol {
  static var hello: Data {
    ADBMessage(
      .connect, 0x0100_0001, 1_048_576,
      payload: Data("host::features=shell_v2,stat_v2,ls_v2,sendrecv_v2\0".utf8)).encoded()
  }
  static func response(to header: Data) throws -> Data {
    let packet = try ADBMessage.decode(header, skipChecksum: true)
    guard packet.command == .startTLS, packet.arg0 == 0x0100_0000 else {
      throw RemoteError.protocolError
    }
    return ADBMessage(.startTLS, 0x0100_0000).encoded()
  }
}

public actor NetworkTransport: ADBTransport {
  private let io: any ADBNetworkIO
  private let sleep: @Sendable (Duration) async throws -> Void
  public init(endpoint: NWEndpoint, startTLS: Bool, identity: ADBIdentity = ADBIdentity()) throws {
    io = try SystemADBNetworkIO(endpoint: endpoint, startTLS: startTLS, identity: identity)
    sleep = { try await Task.sleep(for: $0) }
  }
  init(
    io: any ADBNetworkIO,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.io = io
    self.sleep = sleep
  }

  public func start() async throws {
    let io = io
    let _: Void = try await operation(timeout: RemoteTimeout.deviceRequest) { complete in
      io.start { state in
        switch state {
        case .ready:
          io.stopObservingState()
          complete(.success(()))
        case .failed(let error), .waiting(let error):
          io.stopObservingState()
          complete(.failure(NetworkFailure.posix(error)))
        case .cancelled:
          io.stopObservingState()
          complete(.failure(RemoteError.notConnected))
        default: break
        }
      }
    }
  }
  public func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard count > 0 else { throw RemoteError.invalidPath }
    let io = io
    return try await operation(timeout: timeout) { complete in
      io.receive(count: count) { data, error in
        if let error { complete(.failure(NetworkFailure.posix(error))) }
        else if let data, !data.isEmpty {
          complete(data.count <= count ? .success(data) : .failure(RemoteError.protocolError))
        } else { complete(.failure(RemoteError.notConnected)) }
      }
    }
  }
  public func write(_ data: Data, timeout: TimeInterval) async throws {
    let io = io
    let _: Void = try await operation(timeout: timeout) { complete in
      io.send(data) { error in
        if let error { complete(.failure(NetworkFailure.posix(error))) }
        else { complete(.success(())) }
      }
    }
  }
  public func exporter() throws -> Data {
    guard let data = io.exportedSecret(), data.count == 64 else { throw RemoteError.protocolError }
    return data
  }
  public func close() async { io.cancel() }

  private func operation<Value: Sendable>(
    timeout: TimeInterval,
    register: @escaping @Sendable (@escaping ADBNetworkRequest<Value>.Completion) -> Void
  ) async throws -> Value {
    try Task.checkCancellation()
    guard timeout > 0, timeout.isFinite else { throw RemoteError.posix(ETIMEDOUT) }
    let io = io
    let sleep = sleep
    let request = ADBNetworkRequest<Value>(register: register, cancel: { io.cancel() })
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await request.run() }
      group.addTask {
        try await sleep(.seconds(timeout))
        throw RemoteError.posix(ETIMEDOUT)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw RemoteError.notConnected }
      return result
    }
  }
}

// 排列注册、取消和回调，防止取消早到或状态重复时重复恢复。
private final class ADBNetworkRequest<Value: Sendable>: @unchecked Sendable {
  typealias Completion = @Sendable (Result<Value, Error>) -> Void
  private let queue = DispatchQueue(label: "com.seaony.Kayoi.network.request")
  private let register: @Sendable (@escaping Completion) -> Void
  private let cancel: @Sendable () -> Void
  private var continuation: CheckedContinuation<Value, Error>?
  private var cancelled = false
  private var finished = false
  init(register: @escaping @Sendable (@escaping Completion) -> Void, cancel: @escaping @Sendable () -> Void) {
    self.register = register
    self.cancel = cancel
  }
  func run() async throws -> Value {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          self.continuation = continuation
          if self.cancelled { self.finish(.failure(CancellationError())); return }
          self.register { result in self.queue.async { self.finish(result) } }
        }
      }
    } onCancel: {
      self.queue.async {
        guard !self.finished else { return }
        self.cancelled = true
        self.cancel()
        self.finish(.failure(CancellationError()))
      }
    }
  }
  private func finish(_ result: Result<Value, Error>) {
    guard !finished, let continuation else { return }
    finished = true
    self.continuation = nil
    continuation.resume(with: result)
  }
}
