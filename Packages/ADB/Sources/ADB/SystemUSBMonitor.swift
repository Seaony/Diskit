import Core
import Foundation
import IOKit

@MainActor final class SystemUSBMonitor: USBDiscoverySource {
  private var port: IONotificationPortRef?
  private var added: io_iterator_t = 0
  private var removed: io_iterator_t = 0
  private var changed: (@MainActor () -> Void)?
  public init() {}
  isolated deinit { stop() }
  func start(changed: @escaping @MainActor () -> Void) throws {
    self.changed = changed
    guard port == nil else { return }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
      throw RemoteError.posix(EIO)
    }
    self.port = port
    IONotificationPortSetDispatchQueue(port, .main)
    let callback: IOServiceMatchingCallback = { context, iterator in
      while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        IOObjectRelease(service)
      }
      guard let context else { return }
      MainActor.assumeIsolated {
        Unmanaged<SystemUSBMonitor>.fromOpaque(context).takeUnretainedValue().scan()
      }
    }
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    func match() -> CFMutableDictionary {
      let result = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
      result["bInterfaceClass"] = 0xff
      result["bInterfaceSubClass"] = 0x42
      result["bInterfaceProtocol"] = 1
      return result
    }
    let first = IOServiceAddMatchingNotification(
      port, kIOFirstMatchNotification, match(), callback, pointer, &added)
    let second = IOServiceAddMatchingNotification(
      port, kIOTerminatedNotification, match(), callback, pointer, &removed)
    guard first == KERN_SUCCESS, second == KERN_SUCCESS else {
      let failure = first == KERN_SUCCESS ? second : first
      stop()
      throw USBTransport.mappedError(NSError(domain: NSOSStatusErrorDomain, code: Int(failure)))
    }
    callback(pointer, added)
    callback(pointer, removed)
  }
  func devices() throws -> [ADBDevice] { try ADBUSB.scanDevices() }
  private func scan() {
    changed?()
  }
  func stop() {
    if added != 0 {
      IOObjectRelease(added)
      added = 0
    }
    if removed != 0 {
      IOObjectRelease(removed)
      removed = 0
    }
    if let port {
      IONotificationPortDestroy(port)
      self.port = nil
    }
  }
}
