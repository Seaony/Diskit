import Core
import Foundation

public actor ADBSession: ADBStreamSession {
  private let now: @Sendable () -> ContinuousClock.Instant
  private let transport: any ADBTransport
  private let identity: ADBIdentity
  private let initialConnectSent: Bool
  public private(set) var features: Set<String> = []
  private var version: UInt32 = 0x0100_0001
  private var maxPayload = 4096
  private var local: UInt32 = 0
  private var remote: UInt32?
  private var buffered = Data()
  private var transportFailed = false
  private var serviceDeadline: ADBOperationDeadline?
  static let authorizationTimeout: TimeInterval = 60
  public init(
    transport: any ADBTransport, identity: ADBIdentity = ADBIdentity(),
    initialConnectSent: Bool = false
  ) {
    self.init(transport: transport, identity: identity, initialConnectSent: initialConnectSent, now: { .now })
  }
  init(
    transport: any ADBTransport, identity: ADBIdentity = ADBIdentity(),
    initialConnectSent: Bool = false,
    now: @escaping @Sendable () -> ContinuousClock.Instant
  ) {
    self.now = now
    self.initialConnectSent = initialConnectSent
    self.transport = transport
    self.identity = identity
  }
  private func send(_ message: ADBMessage, deadline: ADBOperationDeadline) async throws {
    do {
      let encoded = message.encoded(
        skipChecksum: version >= 0x0100_0001 && message.command != .connect
          && message.command != .auth)
      try await transport.write(Data(encoded.prefix(24)), timeout: deadline.remaining())
      if !message.payload.isEmpty {
        try await transport.write(message.payload, timeout: deadline.remaining())
        if message.command == .write { deadline.transferred(message.payload.count) }
      }
    } catch {
      transportFailed = true
      throw error
    }
  }
  private func receive(deadline: ADBOperationDeadline) async throws -> ADBMessage {
    do {
      var header = Data()
      while header.count < 24 {
        let bytes = try await transport.read(
          count: 24 - header.count, timeout: deadline.remaining())
        guard !bytes.isEmpty else { throw RemoteError.notConnected }
        header.append(bytes)
      }
      var commandReader = BinaryReader(header)
      let receivedCommand = try commandReader.u32()
      var reader = BinaryReader(Data(header[12..<16]))
      let length = Int(try reader.u32())
      guard length <= 1_048_576 else { throw RemoteError.protocolError }
      var payload = Data()
      while payload.count < length {
        let bytes = try await transport.read(
          count: length - payload.count, timeout: deadline.remaining())
        guard !bytes.isEmpty else { throw RemoteError.notConnected }
        payload.append(bytes)
        if receivedCommand == ADBCommand.write.rawValue { deadline.transferred(bytes.count) }
      }
      var fields = BinaryReader(header)
      let command = try fields.u32()
      let announcedVersion = try fields.u32()
      let skip =
        command == ADBCommand.connect.rawValue
        ? announcedVersion >= 0x0100_0001 : version >= 0x0100_0001
      _ = try deadline.remaining()
      return try ADBMessage.decode(header + payload, skipChecksum: skip)
    } catch {
      transportFailed = true
      throw error
    }
  }
  // 只收发给当前通道的包：关通道时两边会同时发 CLSE，有的手机（如小米 17）会对旧通道再回一个，
  // 官方 adb 遇到不属于现有通道的 OKAY、WRTE、CLSE 直接丢掉，这里照做
  private func receiveStream(deadline: ADBOperationDeadline) async throws -> ADBMessage {
    while true {
      let message = try await receive(deadline: deadline)
      let streamCommands: Set<ADBCommand> = [.okay, .write, .close]
      if streamCommands.contains(message.command), message.arg1 != local { continue }
      return message
    }
  }
  public func connect() async throws {
    guard !transportFailed else { throw RemoteError.notConnected }
    var deadline = ADBOperationDeadline(timeout: RemoteTimeout.deviceRequest, now: now)
    if !initialConnectSent {
      try await send(
        ADBMessage(
          .connect, 0x0100_0001, 1_048_576,
          payload: Data("host::features=shell_v2,stat_v2,ls_v2,sendrecv_v2\0".utf8)),
        deadline: deadline)
    }
    var signed = false
    var sentPublicKey = false
    while true {
      let message: ADBMessage
      do { message = try await receive(deadline: deadline) } catch RemoteError.posix(ETIMEDOUT)
        where sentPublicKey
      { throw RemoteError.unauthorized }
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
          try await send(
            ADBMessage(.auth, 2, payload: identity.sign(message.payload)), deadline: deadline)
          signed = true
        } else if !sentPublicKey {
          try await send(
            ADBMessage(.auth, 3, payload: identity.publicKeyLine()), deadline: deadline)
          sentPublicKey = true
          // 手机此时弹出「允许 USB 调试」，给用户留够点按的时间
          deadline = ADBOperationDeadline(timeout: Self.authorizationTimeout, now: now)
        } else {
          throw RemoteError.unauthorized
        }
      // 上次会话没读走的通道包（比如多出来的 CLSE）还留在 USB 里，握手时还没有通道，直接丢掉
      case .okay, .write, .close: continue
      default: throw RemoteError.protocolError
      }
    }
  }
  public func open(_ service: String) async throws {
    guard remote == nil else { throw RemoteError.posix(EBUSY) }
    let deadline = ADBOperationDeadline(timeout: RemoteTimeout.deviceRequest, now: now)
    serviceDeadline = deadline
    local &+= 1
    buffered.removeAll(keepingCapacity: true)
    try await send(
      ADBMessage(.open, local, payload: Data((service + "\0").utf8)), deadline: deadline)
    let reply = try await receiveStream(deadline: deadline)
    if reply.command == .close, reply.arg1 == local { throw RemoteError.posix(EACCES) }
    guard reply.command == .okay, reply.arg1 == local, reply.arg0 != 0 else {
      transportFailed = true
      throw RemoteError.protocolError
    }
    remote = reply.arg0
  }
  private func accept(_ message: ADBMessage, deadline: ADBOperationDeadline) async throws -> Data? {
    guard let remote, message.arg0 == remote, message.arg1 == local else {
      transportFailed = true
      throw RemoteError.protocolError
    }
    switch message.command {
    case .write:
      try await send(ADBMessage(.okay, local, remote), deadline: deadline)
      return message.payload
    case .close:
      try await send(ADBMessage(.close, local, remote), deadline: deadline)
      self.remote = nil
      return nil
    default:
      transportFailed = true
      throw RemoteError.protocolError
    }
  }
  public func write(_ bytes: Data, timeout: TimeInterval) async throws
  {
    guard let remote else { throw RemoteError.notConnected }
    let deadline = try operationDeadline(timeout: timeout)
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + maxPayload, bytes.count)
      try await send(
        ADBMessage(.write, local, remote, payload: bytes.subdata(in: offset..<end)),
        deadline: deadline)
      while true {
        let reply = try await receiveStream(deadline: deadline)
        if reply.command == .okay, reply.arg0 == remote, reply.arg1 == local { break }
        guard let bytes = try await accept(reply, deadline: deadline) else {
          throw RemoteError.notConnected
        }
        buffered.append(bytes)
      }
      offset = end
    }
  }
  public func readExactly(_ count: Int, timeout: TimeInterval)
    async throws -> Data
  {
    let deadline = try operationDeadline(timeout: timeout)
    while buffered.count < count {
      guard remote != nil,
        let bytes = try await accept(receiveStream(deadline: deadline), deadline: deadline)
      else {
        throw RemoteError.notConnected
      }
      buffered.append(bytes)
    }
    let result = Data(buffered.prefix(count))
    buffered.removeFirst(count)
    return result
  }
  public func readChunk(timeout: TimeInterval) async throws -> Data? {
    let deadline = try operationDeadline(timeout: timeout)
    if !buffered.isEmpty {
      let value = buffered
      buffered = Data()
      return value
    }
    guard remote != nil else { return nil }
    return try await accept(receiveStream(deadline: deadline), deadline: deadline)
  }
  public func closeService() async throws {
    guard let remote else { return }
    let deadline =
      serviceDeadline?.isTransfer == false
      ? serviceDeadline! : ADBOperationDeadline(timeout: RemoteTimeout.deviceRequest, now: now)
    try await send(ADBMessage(.close, local, remote), deadline: deadline)
    while self.remote != nil {
      _ = try await accept(receiveStream(deadline: deadline), deadline: deadline)
    }
    serviceDeadline = nil
    buffered.removeAll(keepingCapacity: true)
  }
  private func operationDeadline(timeout: TimeInterval) throws -> ADBOperationDeadline {
    let transfer = timeout == RemoteTimeout.transferIdle
    if let serviceDeadline, !transfer {
      if timeout == RemoteTimeout.deviceRequest { return serviceDeadline }
      let shortened = ADBOperationDeadline(timeout: min(timeout, try serviceDeadline.remaining()), now: now)
      self.serviceDeadline = shortened
      return shortened
    }
    let deadline = ADBOperationDeadline(timeout: timeout, isTransfer: transfer, now: now)
    serviceDeadline = deadline
    return deadline
  }
  func recoverAfterOperationError(_ error: Error) async -> Bool {
    guard !transportFailed, !(error is CancellationError) else {
      await disconnect()
      return false
    }
    do {
      try await closeService()
      return true
    } catch {
      await disconnect()
      return false
    }
  }
  public func disconnect() async {
    // 手机关通道后可能还会多发几个包（小米 17 对同一通道连发 CLSE），没读走就留在 USB 里，
    // 下次连接时手机有一定概率出错并重启 USB；连接还正常就先读干净再关，最多等 0.3 秒
    if !transportFailed {
      let end = ContinuousClock.now.advanced(by: .milliseconds(300))
      while let left = try? RemoteTimeout.remaining(until: end),
        let bytes = try? await transport.read(count: 4096, timeout: min(0.1, left)), !bytes.isEmpty
      {}
    }
    transportFailed = true
    await transport.close()
    remote = nil
    serviceDeadline = nil
    buffered = Data()
  }
}
