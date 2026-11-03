import Core
import Foundation
import Network
import Security

private func networkDeadline<T: Sendable>(
  _ connection: NWConnection, seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await withTaskCancellationHandler(operation: operation, onCancel: { connection.cancel() })
    }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      connection.cancel()
      throw RemoteError.posix(ETIMEDOUT)
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw RemoteError.notConnected }
    return value
  }
}

final class ADBStartTLS: NWProtocolFramerImplementation {
  static let label = "Kayoi ADB STLS"
  static let definition = NWProtocolFramer.Definition(implementation: ADBStartTLS.self)
  required init(framer: NWProtocolFramer.Instance) {}
  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
    let hello = ADBMessage(
      .connect, 0x0100_0001, 1_048_576,
      payload: Data("host::features=shell_v2,stat_v2,ls_v2,sendrecv_v2\0".utf8))
    framer.writeOutput(data: hello.encoded())
    framer.scheduleWakeup(wakeupTime: .milliseconds(15_000))
    return .willMarkReady
  }
  static func response(to header: Data) throws -> Data {
    let packet = try ADBMessage.decode(header, skipChecksum: true)
    guard packet.command == .startTLS, packet.arg0 == 0x0100_0000 else {
      throw RemoteError.protocolError
    }
    return ADBMessage(.startTLS, 0x0100_0000).encoded()
  }
  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    var header: Data?
    let parsed = framer.parseInput(minimumIncompleteLength: 24, maximumLength: 24) { bytes, _ in
      guard let bytes, bytes.count >= 24 else { return 0 }
      header = Data(bytes.prefix(24))
      return 24
    }
    guard parsed, let header else { return 24 }
    do {
      guard let tls = framer.options["tls"] as? NWProtocolTLS.Options else {
        throw RemoteError.protocolError
      }
      framer.writeOutput(data: try Self.response(to: header))
      try framer.prependApplicationProtocol(options: tls)
      framer.scheduleWakeup(wakeupTime: .forever)
      framer.passThroughInput()
      framer.passThroughOutput()
      framer.markReady()
    } catch { framer.markFailed(error: .posix(.EPROTO)) }
    return 0
  }
  func handleOutput(
    framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int,
    isComplete: Bool
  ) {
    do { try framer.writeOutputNoCopy(length: messageLength) } catch {
      framer.markFailed(error: .posix(.EIO))
    }
  }
  func wakeup(framer: NWProtocolFramer.Instance) { framer.markFailed(error: .posix(.ETIMEDOUT)) }
  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer: NWProtocolFramer.Instance) {}
}

public actor NetworkTransport: ADBTransport {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.seaony.Kayoi.adb.network")
  public init(endpoint: NWEndpoint, startTLS: Bool, identity: ADBIdentity = ADBIdentity()) throws {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try identity.tlsIdentity())
    // AOSP 用配对码与 TLS exporter 认证配对通道，设备证书是自签名的。
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters: NWParameters
    if startTLS {
      parameters = NWParameters(tls: nil, tcp: tcp)
      let framer = NWProtocolFramer.Options(definition: ADBStartTLS.definition)
      framer["tls"] = tls
      parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
    } else {
      parameters = NWParameters(tls: tls, tcp: tcp)
    }
    connection = NWConnection(to: endpoint, using: parameters)
  }
  public func start() async throws {
    let queue = queue
    let connection = connection
    try await networkDeadline(connection, seconds: 15) {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            connection.stateUpdateHandler = nil
            continuation.resume()
          case .failed(let error):
            connection.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          case .cancelled:
            connection.stateUpdateHandler = nil
            continuation.resume(throwing: RemoteError.notConnected)
          default: break
          }
        }
        connection.start(queue: queue)
      }
    }
  }
  public func read(count: Int, timeout: TimeInterval) async throws -> Data {
    let connection = connection
    return try await networkDeadline(connection, seconds: timeout) {
      try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, _, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: RemoteError.notConnected)
          }
        }
      }
    }
  }
  public func write(_ data: Data, timeout: TimeInterval) async throws {
    let connection = connection
    try await networkDeadline(connection, seconds: timeout) {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.send(
          content: data,
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
    }
  }
  public func exporter() throws -> Data {
    guard
      let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else { throw RemoteError.protocolError }
    let label = Array("adb-label\0".utf8)
    let secret = label.withUnsafeBytes { bytes in
      sec_protocol_metadata_create_secret(
        metadata.securityProtocolMetadata, label.count,
        bytes.baseAddress!.assumingMemoryBound(to: CChar.self), 64)
    }
    guard let secret else { throw RemoteError.protocolError }
    var output = Data()
    (secret as DispatchData).enumerateBytes { bytes, _, _ in output.append(bytes) }
    guard output.count == 64 else { throw RemoteError.protocolError }
    return output
  }
  public func close() async { connection.cancel() }
}
