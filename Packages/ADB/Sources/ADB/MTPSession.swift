import Core
import Foundation

// MTP 走 USB 批量端点，还要能在出错时让设备放弃当前事务
protocol MTPChannel: USBChannel {
  func cancel(transactionID: UInt32) async
}

// 一条 MTP 会话：同一时间只跑一个事务（命令 → 可选数据 → 响应）。
// 事务半路断掉后设备和本机对不上，这条会话就作废，由上层重新打开接口建新会话
actor MTPSession {
  enum Outgoing: Sendable {
    case data(Data)
    case file(URL, size: Int64)
  }
  enum Incoming: Sendable {
    case none, collect
    case stream(@Sendable (Data) async throws -> Void)
  }
  struct Result: Sendable {
    var code: UInt16
    var params: [UInt32]
    var data: Data
  }

  private let channel: any MTPChannel
  private var nextTransaction: UInt32 = 0
  private var pending = Data()
  // 最近一次 USB 传输是短包：长度未知的数据阶段靠它判断已经结束
  private var lastReadShort = false
  private(set) var broken = false
  // 每次 USB 传输的块大小：1 MiB，是所有速度下最大包长的整数倍，中途不会出现短包
  static let block = 1 << 20
  private static let readUnit = 16_384

  // 等设备回数据的时限；只问一句型号时用短的，免得设备不答时卡住发现
  private let readTimeout: TimeInterval
  // 当前事务读数据的时限
  private var timeout: TimeInterval = RemoteTimeout.deviceRequest
  // 发命令的时限；设备睡眠、锁屏时不收命令，连接时用短的好隔一会儿重试
  private var commandTimeout: TimeInterval = RemoteTimeout.deviceRequest
  init(channel: any MTPChannel, readTimeout: TimeInterval = RemoteTimeout.transferIdle) {
    self.channel = channel
    self.readTimeout = readTimeout
  }

  func close() async { await channel.close() }

  // 新连接开始前让设备放弃上一个程序没做完的事务（Android 的 MTP 驱动收到 Cancel 类请求就回到等命令的状态），
  // 再把它还没发完的旧数据读空。不做这一步，Android File Transfer 刚退出时设备会不收新命令
  func reset() async {
    await channel.cancel(transactionID: 0)
    await drain()
  }

  // 问设备信息，发命令只等 commandTimeout 秒：设备不收就报 ETIMEDOUT，由上层决定要不要再试
  func deviceInfo(commandTimeout: TimeInterval) async throws -> MTPDeviceInfo {
    self.commandTimeout = commandTimeout
    defer { self.commandTimeout = RemoteTimeout.deviceRequest }
    return try MTPDataset.deviceInfo(try await run(.getDeviceInfo, receive: .collect).data)
  }

  func drain() async {
    for _ in 0..<64 {
      guard let data = try? await channel.read(count: Self.block, timeout: 0.2), !data.isEmpty
      else { return }
    }
  }

  // 跑一个事务，响应码不是 OK 时按设备的拒绝原因报错
  @discardableResult
  func run(
    _ operation: MTPOperation, _ params: [UInt32] = [], send: Outgoing? = nil,
    receive: Incoming = .none, cancellable: Bool = false
  ) async throws -> Result {
    let result = try await raw(
      operation, params, send: send, receive: receive, cancellable: cancellable)
    if result.code == MTPResponse.sessionNotOpen, operation != .getDeviceInfo {
      // 设备那边的会话没了（如设备重启了 MTP 服务）：这条会话作废，按断线交给上层重连
      broken = true
      throw RemoteError.failed(
        ENOTCONN, MTPResponse.error(result.code, operation: operation).errorDescription ?? "")
    }
    guard result.code == MTPResponse.ok else { throw MTPResponse.error(result.code, operation: operation) }
    return result
  }

  // 不检查响应码；只有打开会话要自己处理“会话已打开”
  func raw(
    _ operation: MTPOperation, _ params: [UInt32] = [], send: Outgoing? = nil,
    receive: Incoming = .none, cancellable: Bool = false
  ) async throws -> Result {
    guard !broken else { throw RemoteError.notConnected }
    try Task.checkCancellation()
    // 普通事务很短，不让外面的取消把它切断（切断后会话就作废了）；只有上传大文件允许中途取消
    if cancellable {
      return try await perform(operation, params, send: send, receive: receive)
    }
    return try await Task { try await self.perform(operation, params, send: send, receive: receive) }
      .value
  }

  private func perform(
    _ operation: MTPOperation, _ params: [UInt32], send: Outgoing?, receive: Incoming
  ) async throws -> Result {
    // 传文件内容的操作按“多久没进展”算，其余普通请求 15 秒内要有回应
    let transfers: Set<MTPOperation> = [.getObject, .getPartialObject, .getPartialObject64, .sendObject]
    timeout = min(
      readTimeout,
      transfers.contains(operation) ? RemoteTimeout.transferIdle : RemoteTimeout.deviceRequest)
    // 打开会话前的事务号用 0，打开会话后从 1 开始递增
    let transaction: UInt32
    switch operation {
    case .openSession:
      transaction = 0
      nextTransaction = 1
    case .getDeviceInfo where nextTransaction == 0: transaction = 0
    default:
      transaction = nextTransaction
      nextTransaction &+= 1
    }
    do {
      try await writeCommand(operation, params, transaction: transaction)
      if let send { try await writeData(send, operation: operation, transaction: transaction) }
      var data = Data()
      while true {
        let header = try await readHeader(transaction: transaction)
        switch header.type {
        case 2:
          try await readData(length: header.length) { chunk in
            switch receive {
            case .none: break
            case .collect: data.append(chunk)
            case .stream(let sink): try await sink(chunk)
            }
          }
        case 3:
          let body = try await take(Int(header.length) - 12)
          var reader = MTPReader(body)
          var values: [UInt32] = []
          while reader.remaining >= 4 { values.append(try reader.u32()) }
          return Result(code: header.code, params: values, data: data)
        default:
          throw RemoteError.malformed(
            LF("设备在 %@ 中返回了未知的 MTP 容器类型 %@", operation.name, String(header.type)))
        }
      }
    } catch {
      broken = true
      pending = Data()
      await channel.cancel(transactionID: transaction)
      if error is CancellationError { throw error }
      throw USBTransport.mappedError(error)
    }
  }

  private func writeCommand(_ operation: MTPOperation, _ params: [UInt32], transaction: UInt32)
    async throws
  {
    var command = Data()
    command.appendMTP(UInt32(12 + params.count * 4))
    command.appendMTP(UInt16(1))
    command.appendMTP(operation.rawValue)
    command.appendMTP(transaction)
    for param in params { command.appendMTP(param) }
    let sent = try await channel.write(command, timeout: commandTimeout)
    guard sent == command.count else { throw RemoteError.notConnected }
  }

  private func writeData(_ outgoing: Outgoing, operation: MTPOperation, transaction: UInt32)
    async throws
  {
    let size: Int64
    var file: FileHandle?
    switch outgoing {
    case .data(let data): size = Int64(data.count)
    case .file(let url, let length):
      size = length
      file = try FileHandle(forReadingFrom: url)
    }
    defer { try? file?.close() }
    var buffer = Data()
    let total = size + 12
    buffer.appendMTP(total > Int64(UInt32.max) ? UInt32.max : UInt32(total))
    buffer.appendMTP(UInt16(2))
    buffer.appendMTP(operation.rawValue)
    buffer.appendMTP(transaction)
    if case .data(let data) = outgoing { buffer.append(data) }
    var read: Int64 = 0
    // 中途的每次传输都是整块，最后一块可以短；总长正好是包长整数倍时补一个零长度包表示结束
    while true {
      if let file, read < size, buffer.count < Self.block {
        try Task.checkCancellation()
        let chunk = try file.read(upToCount: Int(min(Int64(Self.block), size - read))) ?? Data()
        guard !chunk.isEmpty else { throw RemoteError.failed(EIO, L("要上传的本地文件在上传途中变短了")) }
        read += Int64(chunk.count)
        buffer.append(chunk)
        continue
      }
      let last = file == nil || read >= size
      if buffer.count >= Self.block || (last && !buffer.isEmpty) {
        let count = last ? min(buffer.count, Self.block) : Self.block
        let piece = buffer.prefix(count)
        let sent = try await channel.write(Data(piece), timeout: RemoteTimeout.transferIdle)
        guard sent == piece.count else { throw RemoteError.notConnected }
        buffer.removeFirst(count)
        continue
      }
      break
    }
    if total % Int64(max(channel.packetSize, 1)) == 0 {
      _ = try await channel.write(Data(), timeout: RemoteTimeout.transferIdle)
    }
  }

  private struct Header {
    var length: UInt32
    var type: UInt16
    var code: UInt16
  }

  private func readHeader(transaction: UInt32) async throws -> Header {
    while true {
      var reader = MTPReader(try await take(12))
      let header = Header(length: try reader.u32(), type: try reader.u16(), code: try reader.u16())
      let id = try reader.u32()
      guard header.length >= 12 else {
        throw RemoteError.malformed(LF("设备返回的 MTP 容器长度不对：%@", String(header.length)))
      }
      if id == transaction { return header }
      // 早先被取消的事务留下的响应，丢掉接着等
      guard header.type == 3, header.length <= 32 else {
        throw RemoteError.malformed(
          LF("设备返回的事务号 %@ 和当前事务 %@ 对不上", String(id), String(transaction)))
      }
      _ = try await take(Int(header.length) - 12)
    }
  }

  // 数据阶段：长度已知时读满为止；超过 4 GB 的对象长度写 0xFFFFFFFF，读到短包为止
  private func readData(length: UInt32, _ sink: (Data) async throws -> Void) async throws {
    if length == UInt32.max {
      if !pending.isEmpty {
        let chunk = pending
        pending = Data()
        try await sink(chunk)
        if lastReadShort { return }
      }
      while true {
        let chunk = try await channel.read(count: Self.block, timeout: timeout)
        if !chunk.isEmpty { try await sink(chunk) }
        if chunk.count < Self.block { return }
      }
    }
    var remaining = Int(length) - 12
    while remaining > 0 {
      if pending.isEmpty { try await fill(wanted: remaining) }
      let count = min(remaining, pending.count)
      let chunk = pending.prefix(count)
      pending.removeFirst(count)
      remaining -= count
      try await sink(Data(chunk))
    }
  }

  private func take(_ count: Int) async throws -> Data {
    while pending.count < count { try await fill(wanted: count - pending.count) }
    let result = pending.prefix(count)
    pending.removeFirst(count)
    return Data(result)
  }

  // 读一次 USB 传输。零长度包是上一段数据的结束标记，跳过
  private func fill(wanted: Int) async throws {
    let rounded = (wanted + Self.readUnit - 1) / Self.readUnit * Self.readUnit
    let count = min(max(rounded, Self.readUnit), Self.block)
    while true {
      let chunk = try await channel.read(count: count, timeout: timeout)
      if chunk.isEmpty { continue }
      lastReadShort = chunk.count < count
      pending.append(chunk)
      return
    }
  }
}
