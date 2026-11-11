import ADB
import Core
import Foundation
import IOKit
import Security

/// 验证第 4 条：在扩展进程里用 IOUSBHost 打开安卓手机的 ADB 接口并完成握手。
enum SpikeUSBCheck {
  static func run() async -> String {
    let devices = ADBUSB.devices()
    guard let device = devices.first else { return "没找到 ADB USB 设备（扩展进程内枚举到 0 台）" }
    var lines = ["枚举到 \(devices.count) 台：\(device.name) 序列号 \(device.serial)", rawOpenResult()]
    do {
      let transport = try USBTransport(device: device)
      let session = ADBSession(transport: transport, identity: ADBIdentity(store: SpikeKeychainStore()))
      try await session.connect()
      lines.append("握手成功，features 共 \(await session.features.count) 项")
      await session.disconnect()
    } catch {
      lines.append("失败：\(error)")
    }
    return lines.joined(separator: "\n")
  }
}

/// 直接对 ADB 接口调 IOServiceOpen，拿到内核返回码，用来区分是沙盒拦截还是被别的进程占用。
private func rawOpenResult() -> String {
  let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
  match[kIOPropertyMatchKey] = ["bInterfaceClass": 0xff, "bInterfaceSubClass": 0x42, "bInterfaceProtocol": 1]
  let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
  guard service != 0 else { return "IOServiceOpen：找不到接口" }
  defer { IOObjectRelease(service) }
  var connect: io_connect_t = 0
  let result = IOServiceOpen(service, mach_task_self_, 0, &connect)
  if result == KERN_SUCCESS { IOServiceClose(connect) }
  return String(format: "IOServiceOpen 返回 0x%08x", result)
}

/// 验证用：ADB 私钥存进共享钥匙串访问组，扩展重启后还是同一把钥匙，手机只需授权一次。
struct SpikeKeychainStore: SecretStore {
  private func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: SpikeShared.keychainService,
      kSecAttrAccount as String: key, kSecAttrAccessGroup as String: SpikeShared.keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  func read(_ key: String) throws -> Data? {
    var attributes = query(key)
    attributes[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return result as? Data
  }

  func write(_ data: Data, for key: String) throws {
    SecItemDelete(query(key) as CFDictionary)
    var insert = query(key)
    insert[kSecValueData as String] = data
    let status = SecItemAdd(insert as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  func delete(_ key: String) throws { SecItemDelete(query(key) as CFDictionary) }
}
