import Core
import Foundation
import IOKit
import IOUSBHost

actor SystemUSBChannel: USBChannel {
  private var interface: IOUSBHostInterface?
  private var input: IOUSBHostPipe?
  private var output: IOUSBHostPipe?
  nonisolated let packetSize: Int
  init(device: ADBDevice) throws {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
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
        alternate: current.bAlternateSetting)
      let input = try interface.copyPipe(withAddress: endpoints.input)
      let output = try interface.copyPipe(withAddress: endpoints.output)
      self.interface = interface
      self.input = input
      self.output = output
      self.packetSize = endpoints.packetSize
    } catch {
      opened?.destroy()
      throw USBTransport.mappedError(error)
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
  func close() async {
    interface?.destroy()
    input = nil
    output = nil
    interface = nil
  }
}
