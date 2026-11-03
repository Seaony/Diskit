import Foundation
import IOKit
import Observation

@MainActor @Observable public final class USBDiscovery {
  public private(set) var devices: [ADBDevice] = []
  private var port: IONotificationPortRef?
  private var added: io_iterator_t = 0
  private var removed: io_iterator_t = 0
  public var changed: (([ADBDevice]) -> Void)?
  public init() {}
  public func start() {
    guard port == nil else { return }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
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
        Unmanaged<USBDiscovery>.fromOpaque(context).takeUnretainedValue().scan()
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
    IOServiceAddMatchingNotification(
      port, kIOFirstMatchNotification, match(), callback, pointer, &added)
    IOServiceAddMatchingNotification(
      port, kIOTerminatedNotification, match(), callback, pointer, &removed)
    callback(pointer, added)
    callback(pointer, removed)
  }
  private func scan() {
    devices = ADBUSB.devices()
    changed?(devices)
  }
  public func stop() {
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
