import Core
import Foundation
import IOKit
import IOUSBHost

// 这个 USB 接口拿来做什么：报错时说清是 USB 调试接口还是文件传输（MTP）接口
enum USBInterfaceRole: Sendable {
  case adb, mtp
}

actor SystemUSBChannel: MTPChannel {
  private var interface: IOUSBHostInterface?
  private var interfaceNumber: UInt16 = 0
  private var input: IOUSBHostPipe?
  private var output: IOUSBHostPipe?
  nonisolated let packetSize: Int
  init(device: ADBDevice) throws { try self.init(registryID: device.registryID, role: .adb) }
  init(registryID: UInt64, role: USBInterfaceRole) throws {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
    guard service != 0 else { throw RemoteError.notConnected }
    defer { IOObjectRelease(service) }
    var opened: IOUSBHostInterface?
    do {
      let interface = try IOUSBHostInterface(
        __ioService: service, options: [], queue: nil, interestHandler: nil)
      opened = interface
      let descriptor = interface.configurationDescriptor
      let descriptorLength = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
      let current = interface.interfaceDescriptor.pointee
      let endpoints = try USBBulkEndpoints.parse(
        Data(bytes: descriptor, count: descriptorLength), interface: current.bInterfaceNumber,
        alternate: current.bAlternateSetting, checksADB: role == .adb)
      let input = try interface.copyPipe(withAddress: endpoints.input)
      let output = try interface.copyPipe(withAddress: endpoints.output)
      self.interface = interface
      self.input = input
      self.output = output
      self.packetSize = endpoints.packetSize
      self.interfaceNumber = UInt16(current.bInterfaceNumber)
    } catch {
      opened?.destroy()
      // 被别的程序独占时 IOUSBHost 只报笼统的 internal error（0xe00002c9），
      // 系统注册表里的 UsbExclusiveOwner 写着是谁占着（如 "pid 14435, adb"）
      let owner = IORegistryEntryCreateCFProperty(
        service, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
      if let owner, !owner.isEmpty { throw USBTransport.occupied(by: owner, role: role) }
      throw USBTransport.mappedOpenError(error, role: role)
    }
  }

  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard let input else { throw RemoteError.notConnected }
    guard let buffer = NSMutableData(length: count) else { throw RemoteError.posix(ENOMEM) }
    let transferred = try await USBIORequest.perform(pipe: input, buffer: buffer, timeout: timeout)
    guard transferred >= 0, transferred <= count else { throw RemoteError.protocolError }
    return buffer.subdata(with: NSRange(location: 0, length: transferred))
  }
  func write(_ data: Data, timeout: TimeInterval) async throws -> Int {
    guard let output else { throw RemoteError.notConnected }
    return try await USBIORequest.perform(
      pipe: output, buffer: data.isEmpty ? nil : NSMutableData(data: data), timeout: timeout)
  }
  // MTP 的类请求 Cancel（0x64）：让设备放弃这个事务，再清掉两个端点的停滞状态。设备不理也不影响后面重连
  func cancel(transactionID: UInt32) async {
    guard let interface else { return }
    var payload = Data()
    payload.appendMTP(UInt16(0x4001))
    payload.appendMTP(transactionID)
    let request = IOUSBDeviceRequest(
      bmRequestType: 0x21, bRequest: 0x64, wValue: 0, wIndex: interfaceNumber, wLength: 6)
    _ = try? interface.__send(
      request, data: NSMutableData(data: payload), bytesTransferred: nil, completionTimeout: 2)
    try? input?.clearStall()
    try? output?.clearStall()
  }

  func close() async {
    interface?.destroy()
    input = nil
    output = nil
    interface = nil
  }
}
