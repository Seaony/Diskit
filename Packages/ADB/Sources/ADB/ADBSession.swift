import Core
import Foundation

public actor ADBSession {
  private let transport: any ADBTransport
  private let identity: ADBIdentity
  private let initialConnectSent: Bool
  public private(set) var features: Set<String> = []
  private var version: UInt32 = 0x0100_0001
  private var maxPayload = 4096
  private var local: UInt32 = 0
  private var remote: UInt32?
  private var buffered = Data()
  public init(
    transport: any ADBTransport, identity: ADBIdentity = ADBIdentity(),
    initialConnectSent: Bool = false
  ) {
    self.initialConnectSent = initialConnectSent
    self.transport = transport
    self.identity = identity
  }
  private func send(_ message: ADBMessage, timeout: TimeInterval = 15) async throws {
    let encoded = message.encoded(
      skipChecksum: version >= 0x0100_0001 && message.command != .connect
        && message.command != .auth)
    try await transport.write(Data(encoded.prefix(24)), timeout: timeout)
    if !message.payload.isEmpty { try await transport.write(message.payload, timeout: timeout) }
  }
  private func receive(timeout: TimeInterval = 15) async throws -> ADBMessage {
    var header = Data()
    while header.count < 24 {
      header.append(try await transport.read(count: 24 - header.count, timeout: timeout))
    }
    var reader = BinaryReader(Data(header[12..<16]))
    let length = Int(try reader.u32())
    guard length <= 1_048_576 else { throw RemoteError.protocolError }
    var payload = Data()
    while payload.count < length {
      payload.append(try await transport.read(count: length - payload.count, timeout: timeout))
    }
    var fields = BinaryReader(header)
    let command = try fields.u32()
    let announcedVersion = try fields.u32()
    let skip =
      command == ADBCommand.connect.rawValue
      ? announcedVersion >= 0x0100_0001 : version >= 0x0100_0001
    return try ADBMessage.decode(header + payload, skipChecksum: skip)
  }
  public func connect() async throws {
    if !initialConnectSent {
      try await send(
        ADBMessage(
          .connect, 0x0100_0001, 1_048_576,
          payload: Data("host::features=shell_v2,stat_v2,ls_v2,sendrecv_v2\0".utf8)))
    }
    var signed = false
    var sentPublicKey = false
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      let seconds =
        Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
      guard seconds > 0 else { throw RemoteError.unauthorized }
      let message = try await receive(timeout: sentPublicKey ? seconds : min(15, seconds))
      switch message.command {
      case .connect:
        guard message.arg1 > 0 else { throw RemoteError.protocolError }
        version = min(message.arg0, 0x0100_0001)
        maxPayload = min(Int(message.arg1), 1_048_576)
        let banner = String(decoding: message.payload, as: UTF8.self)
        if let range = banner.range(of: "features=") {
          features = Set(
            banner[range.upperBound...].prefix { $0 != ";" && $0 != "\0" }.split(separator: ",")
              .map(String.init))
        }
        return
      case .auth where message.arg0 == 1:
        if !signed {
          try await send(ADBMessage(.auth, 2, payload: identity.sign(message.payload)))
          signed = true
        } else if !sentPublicKey {
          try await send(ADBMessage(.auth, 3, payload: identity.publicKeyLine()))
          sentPublicKey = true
        } else {
          throw RemoteError.unauthorized
        }
      default: throw RemoteError.protocolError
      }
    }
  }
  public func open(_ service: String) async throws {
    guard remote == nil else { throw RemoteError.posix(EBUSY) }
    local &+= 1
    buffered.removeAll(keepingCapacity: true)
    try await send(ADBMessage(.open, local, payload: Data((service + "\0").utf8)))
    let reply = try await receive()
    guard reply.command == .okay, reply.arg1 == local, reply.arg0 != 0 else {
      throw RemoteError.posix(EACCES)
    }
    remote = reply.arg0
  }
  private func accept(_ message: ADBMessage) async throws -> Data? {
    guard let remote, message.arg0 == remote, message.arg1 == local else {
      throw RemoteError.protocolError
    }
    switch message.command {
    case .write:
      try await send(ADBMessage(.okay, local, remote))
      return message.payload
    case .close:
      try await send(ADBMessage(.close, local, remote))
      self.remote = nil
      return nil
    default: throw RemoteError.protocolError
    }
  }
  public func write(_ bytes: Data, timeout: TimeInterval = 15) async throws {
    guard let remote else { throw RemoteError.notConnected }
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + maxPayload, bytes.count)
      try await send(
        ADBMessage(.write, local, remote, payload: bytes.subdata(in: offset..<end)),
        timeout: timeout)
      while true {
        let reply = try await receive(timeout: timeout)
        if reply.command == .okay, reply.arg0 == remote, reply.arg1 == local { break }
        guard let bytes = try await accept(reply) else { throw RemoteError.notConnected }
        buffered.append(bytes)
      }
      offset = end
    }
  }
  public func readExactly(_ count: Int, timeout: TimeInterval = 15) async throws -> Data {
    while buffered.count < count {
      guard remote != nil, let bytes = try await accept(receive(timeout: timeout)) else {
        throw RemoteError.notConnected
      }
      buffered.append(bytes)
    }
    let result = Data(buffered.prefix(count))
    buffered.removeFirst(count)
    return result
  }
  public func readChunk(timeout: TimeInterval = 15) async throws -> Data? {
    if !buffered.isEmpty {
      let value = buffered
      buffered = Data()
      return value
    }
    guard remote != nil else { return nil }
    return try await accept(receive(timeout: timeout))
  }
  public func closeService() async throws {
    guard let remote else { return }
    try await send(ADBMessage(.close, local, remote))
    while self.remote != nil { _ = try await accept(receive()) }
    buffered.removeAll(keepingCapacity: true)
  }
  public func disconnect() async {
    await transport.close()
    remote = nil
    buffered = Data()
  }
}
