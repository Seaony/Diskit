import Core
import Foundation
import IOKit

public protocol ADBTransport: Sendable {
  func read(count: Int, timeout: TimeInterval) async throws -> Data
  func write(_ data: Data, timeout: TimeInterval) async throws
  func close() async
}

protocol USBChannel: Sendable {
  var packetSize: Int { get }
  func read(count: Int, timeout: TimeInterval) async throws -> Data
  func write(_ data: Data, timeout: TimeInterval) async throws -> Int
  func close() async
}

public actor USBTransport: ADBTransport {
  private let channel: any USBChannel
  private var closed = false
  public init(device: ADBDevice) throws { channel = try SystemUSBChannel(device: device) }
  init(channel: any USBChannel) { self.channel = channel }

  public func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !closed else { throw RemoteError.notConnected }
    guard count > 0 else { throw RemoteError.protocolError }
    let end = ContinuousClock.now.advanced(by: .seconds(timeout))
    do {
      while true {
        try Task.checkCancellation()
        let bytes = try await channel.read(
          count: count, timeout: RemoteTimeout.remaining(until: end))
        guard bytes.count <= count else { throw RemoteError.protocolError }
        if !bytes.isEmpty { return bytes }
      }
    } catch { throw Self.mappedError(error) }
  }
  public func write(_ data: Data, timeout: TimeInterval) async throws {
    guard !closed else { throw RemoteError.notConnected }
    guard channel.packetSize > 0 else { throw RemoteError.protocolError }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    do {
      try Task.checkCancellation()
      let transferred = try await channel.write(
        data, timeout: RemoteTimeout.remaining(until: deadline))
      guard transferred == data.count else { throw RemoteError.notConnected }
      if !data.isEmpty, data.count % channel.packetSize == 0 {
        let zero = try await channel.write(
          Data(), timeout: RemoteTimeout.remaining(until: deadline))
        guard zero == 0 else { throw RemoteError.protocolError }
      }
    } catch { throw Self.mappedError(error) }
  }
  public func close() async {
    guard !closed else { return }
    closed = true
    await channel.close()
  }

  static func mappedError(_ error: Error) -> Error {
    if error is CancellationError || error is RemoteError { return error }
    let failure = error as NSError
    if failure.domain == NSPOSIXErrorDomain { return error }
    switch failure.code {
    case Int(kIOReturnExclusiveAccess), Int(kIOReturnBusy): return RemoteError.occupied
    case Int(kIOReturnNotPrivileged), Int(kIOReturnNotPermitted): return RemoteError.posix(EACCES)
    case Int(kIOReturnNoDevice): return RemoteError.posix(ENODEV)
    case Int(kIOReturnTimeout): return RemoteError.posix(ETIMEDOUT)
    default:
      return RemoteError.failed(
        EIO, LF("和手机的 USB 通信出错：%@", USBTransport.describe(failure)))
    }
  }

  static func mappedOpenError(_ error: Error) -> Error {
    let mapped = mappedError(error)
    if case .failed? = mapped as? RemoteError {
      return RemoteError.failed(
        EIO, LF("打不开手机的 USB 调试接口：%@", USBTransport.describe(error as NSError)))
    }
    return mapped
  }

  // owner 是系统记的独占者，格式 "pid 14435, adb"；拆成程序名和进程号给人看
  static func occupied(by owner: String) -> RemoteError {
    let parts = owner.split(separator: ",", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    if parts.count == 2, parts[0].hasPrefix("pid "), !parts[1].isEmpty {
      return .failed(
        EBUSY,
        LF("手机的 USB 调试接口正被电脑上的“%@”（进程 %@）占用，关掉它后重试", parts[1],
          String(parts[0].dropFirst(4))))
    }
    return .failed(EBUSY, LF("手机的 USB 调试接口正被电脑上的“%@”占用，关掉它后重试", owner))
  }

  // IOKit 错误码的系统说明，加上错误域、十六进制码和 IOUSBHost 给的原因
  static func describe(_ failure: NSError) -> String {
    let code = Int32(truncatingIfNeeded: failure.code)
    var text = String(cString: mach_error_string(code))
    if let reason = failure.localizedFailureReason, !reason.isEmpty { text += "，" + reason }
    return text + "（\(failure.domain) 0x\(String(UInt32(bitPattern: code), radix: 16))）"
  }
}
