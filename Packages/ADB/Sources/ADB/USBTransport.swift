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

  static func mappedOpenError(_ error: Error, role: USBInterfaceRole = .adb) -> Error {
    let mapped = mappedError(error)
    if case .failed? = mapped as? RemoteError {
      let detail = USBTransport.describe(error as NSError)
      return RemoteError.failed(
        EIO,
        role == .adb
          ? LF("打不开手机的 USB 调试接口：%@", detail) : LF("打不开设备的 USB 文件传输接口：%@", detail))
    }
    return mapped
  }

  // owner 是系统记的独占者，格式 "pid 14435, adb"；拆成程序名和进程号给人看。
  // 系统只留前 16 个字符，Android File Transfer 会被截成 "Android File Tra"
  static func occupied(by owner: String, role: USBInterfaceRole = .adb) -> RemoteError {
    let parts = owner.split(separator: ",", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let hasProcess = parts.count == 2 && parts[0].hasPrefix("pid ") && !parts[1].isEmpty
    let name = hasProcess ? parts[1] : owner
    let process = hasProcess ? String(parts[0].dropFirst(4)) : nil
    if role == .mtp, "Android File Transfer".hasPrefix(name), name.hasPrefix("Android File") {
      // 它的后台助手是登录项，每次插上安卓设备都会把它重新打开、抢走接口
      return .failed(
        EBUSY,
        L("设备正被 Android File Transfer 占用，请退出它后重试。插上设备时登录项“Android File Transfer Agent”会自动打开它，可在“系统设置 > 通用 > 登录项与扩展”里关掉。"))
    }
    switch (role, process) {
    case (.adb, let process?):
      return .failed(
        EBUSY, LF("手机的 USB 调试接口正被电脑上的“%@”（进程 %@）占用，关掉它后重试", name, process))
    case (.adb, nil):
      return .failed(EBUSY, LF("手机的 USB 调试接口正被电脑上的“%@”占用，关掉它后重试", name))
    case (.mtp, let process?):
      return .failed(
        EBUSY, LF("设备的 USB 文件传输接口正被电脑上的“%@”（进程 %@）占用，关掉它后重试", name, process))
    case (.mtp, nil):
      return .failed(EBUSY, LF("设备的 USB 文件传输接口正被电脑上的“%@”占用，关掉它后重试", name))
    }
  }

  // IOKit 错误码的系统说明，加上错误域、十六进制码和 IOUSBHost 给的原因
  static func describe(_ failure: NSError) -> String {
    let code = Int32(truncatingIfNeeded: failure.code)
    var text = String(cString: mach_error_string(code))
    if let reason = failure.localizedFailureReason, !reason.isEmpty { text += "，" + reason }
    return text + "（\(failure.domain) 0x\(String(UInt32(bitPattern: code), radix: 16))）"
  }
}
