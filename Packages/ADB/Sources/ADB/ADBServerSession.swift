import Core
import Foundation
import Network

// 电脑上跑着 adb server（Android Studio、命令行 adb、scrcpy 等都会启动它）时，它独占手机的
// USB 调试接口，Diskit 打不开。这时经它转发：每个服务单独连一次 127.0.0.1:5037，
// 先发 host:transport:<序列号> 选中手机，再发服务名，之后就是和手机之间的原始数据流。
// 协议见 AOSP packages/modules/adb 的 SERVICES.TXT 和 OVERVIEW.TXT
actor ADBServerSession: ADBStreamSession {
  enum Availability { case ready, unauthorized, unavailable }

  let serial: String
  private let dial: @Sendable () async throws -> any ADBTransport
  private(set) var features: Set<String> = []
  private var stream: (any ADBTransport)?
  private var buffered = Data()
  // 普通请求从开服务起共用一个期限，和直连一致；传输类请求按每次无进展计时
  private var serviceDeadline: ContinuousClock.Instant?

  init(serial: String, dial: @escaping @Sendable () async throws -> any ADBTransport = dialLocalServer) {
    self.serial = serial
    self.dial = dial
  }

  static func dialLocalServer() async throws -> any ADBTransport {
    let transport = NetworkTransport(
      plainTCP: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 5037)!))
    do {
      try await transport.start()
      return transport
    } catch {
      await transport.close()
      throw error
    }
  }

  // adb server 没在跑、没连着这台手机都算不可用；手机还没允许这台电脑的 adb 密钥算未授权
  func availability() async throws -> Availability {
    let list: Data
    do { list = try await query("host:devices") } catch is CancellationError {
      throw CancellationError()
    } catch { return .unavailable }
    for line in String(decoding: list, as: UTF8.self).split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, fields[0] == serial else { continue }
      switch fields[1] {
      case "device": return .ready
      case "unauthorized": return .unauthorized
      default: return .unavailable
      }
    }
    return .unavailable
  }

  func connect() async throws {
    let reply = try await query("host-serial:\(serial):features")
    features = Set(
      String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",").map(String.init))
  }

  func open(_ service: String) async throws {
    guard stream == nil else { throw RemoteError.posix(EBUSY) }
    let transport = try await dial()
    do {
      try await request("host:transport:\(serial)", on: transport)
      try await request(service, on: transport)
    } catch {
      await transport.close()
      throw error
    }
    stream = transport
    buffered.removeAll(keepingCapacity: true)
    serviceDeadline = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
  }

  private func end(_ timeout: TimeInterval) -> ContinuousClock.Instant {
    if timeout == RemoteTimeout.deviceRequest, let serviceDeadline { return serviceDeadline }
    return ContinuousClock.now.advanced(by: .seconds(timeout))
  }

  func write(_ bytes: Data, timeout: TimeInterval) async throws {
    guard let stream else { throw RemoteError.notConnected }
    try await stream.write(bytes, timeout: RemoteTimeout.remaining(until: end(timeout)))
  }

  func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
    guard let stream else { throw RemoteError.notConnected }
    let deadline = end(timeout)
    while buffered.count < count {
      // 一次多读一些，剩下的留给下次，少走几次系统调用
      let bytes = try await stream.read(
        count: max(count - buffered.count, 65_536), timeout: RemoteTimeout.remaining(until: deadline))
      buffered.append(bytes)
    }
    let result = Data(buffered.prefix(count))
    buffered.removeFirst(count)
    return result
  }

  // 服务结束时 adb server 关掉这条连接，读到结尾就返回 nil
  func readChunk(timeout: TimeInterval) async throws -> Data? {
    if !buffered.isEmpty {
      defer { buffered = Data() }
      return buffered
    }
    guard let stream else { return nil }
    do {
      return try await stream.read(count: 65_536, timeout: RemoteTimeout.remaining(until: end(timeout)))
    } catch RemoteError.notConnected {
      await closeStream()
      return nil
    }
  }

  func closeService() async throws { await closeStream() }

  // 每个服务各用一条连接，出错时关掉这一条，下次操作重新连
  func recoverAfterOperationError(_ error: Error) async -> Bool {
    await closeStream()
    return true
  }

  func disconnect() async { await closeStream() }

  private func closeStream() async {
    buffered = Data()
    serviceDeadline = nil
    guard let stream else { return }
    self.stream = nil
    await stream.close()
  }

  // host: 开头的查询：发请求、收 OKAY 和带 4 位十六进制长度的结果，连接用完就关
  private func query(_ text: String) async throws -> Data {
    let transport = try await dial()
    do {
      try await request(text, on: transport)
      let length = try await hexLength(on: transport)
      let reply = try await read(length, on: transport)
      await transport.close()
      return reply
    } catch {
      await transport.close()
      throw error
    }
  }

  private func request(_ text: String, on transport: any ADBTransport) async throws {
    let payload = Data(text.utf8)
    try await transport.write(
      Data(String(format: "%04x", payload.count).utf8) + payload, timeout: RemoteTimeout.deviceRequest)
    let status = try await read(4, on: transport)
    if status == Data("OKAY".utf8) { return }
    guard status == Data("FAIL".utf8) else { throw RemoteError.protocolError }
    let message = String(decoding: try await read(try await hexLength(on: transport), on: transport), as: UTF8.self)
    if message.contains("unauthorized") { throw RemoteError.unauthorized }
    // 手机拔掉或离线算断线（ENODEV），卷会重新选连接方式（比如改走 Wi-Fi 或直连）
    let gone = ["not found", "offline", "no devices"].contains { message.contains($0) }
    throw RemoteError.failed(
      gone ? ENODEV : EIO, LF("电脑上的 adb server 拒绝了请求“%@”：%@", text, message))
  }

  private func hexLength(on transport: any ADBTransport) async throws -> Int {
    let text = String(decoding: try await read(4, on: transport), as: UTF8.self)
    guard let length = Int(text, radix: 16) else { throw RemoteError.protocolError }
    return length
  }

  private func read(_ count: Int, on transport: any ADBTransport) async throws -> Data {
    var data = Data()
    let end = ContinuousClock.now.advanced(by: .seconds(RemoteTimeout.deviceRequest))
    while data.count < count {
      data.append(
        try await transport.read(count: count - data.count, timeout: RemoteTimeout.remaining(until: end)))
    }
    return data
  }
}
