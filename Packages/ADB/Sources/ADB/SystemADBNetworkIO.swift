import Foundation
import Network
import Security

// 仅转换 Network 与 Security 的系统调用，状态和数据判断由 NetworkTransport 负责。
final class SystemADBNetworkIO: ADBNetworkIO, @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.seaony.Diskit.adb.network")
  init(endpoint: NWEndpoint, startTLS: Bool, identity: ADBIdentity) throws {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try identity.tlsIdentity())
    // AOSP 用配对码与 TLS exporter 认证配对通道，设备证书是自签名的。
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: startTLS ? nil : tls, tcp: tcp)
    if startTLS {
      let framer = NWProtocolFramer.Options(definition: ADBStartTLS.definition)
      framer["tls"] = tls
      parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
    }
    connection = NWConnection(to: endpoint, using: parameters)
  }
  init(plainTCP endpoint: NWEndpoint) {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
  }
  func start(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
    connection.stateUpdateHandler = handler
    connection.start(queue: queue)
  }
  func stopObservingState() { connection.stateUpdateHandler = nil }
  func receive(count: Int, completion: @escaping @Sendable (Data?, NWError?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, _, error in
      completion(data, error)
    }
  }
  func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
    connection.send(content: data, completion: .contentProcessed(completion))
  }
  func exportedSecret() -> Data? {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
    let label = Array("adb-label\0".utf8)
    let secret = label.withUnsafeBytes { bytes in
      sec_protocol_metadata_create_secret(
        metadata.securityProtocolMetadata, label.count,
        bytes.baseAddress!.assumingMemoryBound(to: CChar.self), 64)
    }
    guard let secret else { return nil }
    var output = Data()
    (secret as DispatchData).enumerateBytes { bytes, _, _ in output.append(bytes) }
    return output
  }
  func cancel() {
    stopObservingState()
    connection.cancel()
  }
}
