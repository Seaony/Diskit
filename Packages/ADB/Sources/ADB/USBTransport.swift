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
    default: return RemoteError.posix(EIO)
    }
  }
}
