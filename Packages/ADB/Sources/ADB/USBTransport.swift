import Core
import Foundation
import IOKit
import IOUSBHost

public struct ADBDevice: Identifiable, Sendable, Equatable {
  public var id: String { serial }
  public let serial: String
  public let name: String
  public let registryID: UInt64
}

public enum ADBUSB {
  public static func devices() -> [ADBDevice] {
    let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
    match["bInterfaceClass"] = 0xff
    match["bInterfaceSubClass"] = 0x42
    match["bInterfaceProtocol"] = 1
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
      return []
    }
    defer { IOObjectRelease(iterator) }
    var found: [ADBDevice] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      func number(_ key: String) -> Int? {
        (IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, key as CFString, kCFAllocatorDefault, 0) as? NSNumber)?.intValue
      }
      guard number("bInterfaceClass") == 0xff, number("bInterfaceSubClass") == 0x42,
        number("bInterfaceProtocol") == 1
      else { continue }

      func property(_ key: String) -> String? {
        IORegistryEntrySearchCFProperty(
          service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
      }
      guard let serial = property("USB Serial Number"), !serial.isEmpty else { continue }
      var registryID: UInt64 = 0
      IORegistryEntryGetRegistryEntryID(service, &registryID)
      found.append(
        ADBDevice(
          serial: serial, name: property("USB Product Name") ?? serial, registryID: registryID))
    }
    return found
  }
}

public protocol ADBTransport: Sendable {
  func read(count: Int, timeout: TimeInterval) async throws -> Data
  func write(_ data: Data, timeout: TimeInterval) async throws
  func close() async
}

public actor USBTransport: ADBTransport {
  private var interface: IOUSBHostInterface?
  private var input: IOUSBHostPipe?
  private var output: IOUSBHostPipe?
  private var packetSize = 512
  public init(device: ADBDevice) throws {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
    guard service != 0 else { throw RemoteError.notConnected }
    defer { IOObjectRelease(service) }
    do {
      let interface = try IOUSBHostInterface(
        __ioService: service, options: [], queue: nil, interestHandler: nil)
      self.interface = interface
      let descriptor = interface.configurationDescriptor
      let bytes = UnsafeRawPointer(descriptor).assumingMemoryBound(to: UInt8.self)
      let length = Int(descriptor.pointee.wTotalLength)
      let number = interface.interfaceDescriptor.pointee.bInterfaceNumber
      var position = 0
      var selected = false
      while position + 2 <= length {
        let size = Int(bytes[position])
        let type = bytes[position + 1]
        guard size >= 2, position + size <= length else { throw RemoteError.protocolError }
        if type == 4, size >= 9 {
          selected = bytes[position + 2] == number && bytes[position + 3] == 0
        }
        if selected, type == 5, size >= 7, bytes[position + 3] & 3 == 2 {
          let address = Int(bytes[position + 2])
          let pipe = try interface.copyPipe(withAddress: address)
          if address & 0x80 != 0 {
            input = pipe
          } else {
            output = pipe
            packetSize = Int(bytes[position + 4]) | Int(bytes[position + 5]) << 8
          }
        }
        position += size
      }
      guard input != nil, output != nil, packetSize > 0 else {
        interface.destroy()
        throw RemoteError.protocolError
      }
    } catch {
      interface?.destroy()
      let code = (error as NSError).code
      if code == Int(kIOReturnExclusiveAccess) || code == Int(kIOReturnBusy) {
        throw RemoteError.occupied
      }
      throw error
    }
  }
  public func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard let input else { throw RemoteError.notConnected }
    guard let buffer = NSMutableData(length: count) else { throw RemoteError.posix(ENOMEM) }
    var transferred = 0
    let end = Date().addingTimeInterval(timeout)
    repeat {
      let remaining = end.timeIntervalSinceNow
      guard remaining > 0 else { throw RemoteError.posix(ETIMEDOUT) }
      do {
        try input.__sendIORequest(
          with: buffer, bytesTransferred: &transferred, completionTimeout: remaining)
      } catch {
        throw RemoteError.posix((error as NSError).code == Int(kIOReturnTimeout) ? ETIMEDOUT : EIO)
      }
    } while transferred == 0
    guard transferred <= count else { throw RemoteError.protocolError }
    return buffer.subdata(with: NSRange(location: 0, length: transferred))
  }
  public func write(_ data: Data, timeout: TimeInterval) async throws {
    guard let output else { throw RemoteError.notConnected }
    var transferred = 0
    do {
      try output.__sendIORequest(
        with: NSMutableData(data: data), bytesTransferred: &transferred, completionTimeout: timeout)
      guard transferred == data.count else { throw RemoteError.notConnected }
      if !data.isEmpty, data.count % packetSize == 0 {
        try output.__sendIORequest(
          with: nil, bytesTransferred: &transferred, completionTimeout: timeout)
      }
    } catch {
      throw RemoteError.posix((error as NSError).code == Int(kIOReturnTimeout) ? ETIMEDOUT : EIO)
    }
  }
  public func close() async {
    interface?.destroy()
    input = nil
    output = nil
    interface = nil
  }
}
