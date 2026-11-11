import ADB
import Core
import Foundation
import Security

/// 验证第 4 条：在扩展进程里用 IOUSBHost 打开安卓手机的 ADB 接口，完成握手并读一个属性。
enum SpikeUSBCheck {
  static func run() async -> String {
    let devices = ADBUSB.devices()
    guard let device = devices.first else { return "没找到 ADB USB 设备（扩展进程内枚举到 0 台）" }
    var lines = ["枚举到 \(devices.count) 台：\(device.name) 序列号 \(device.serial)"]
    do {
      let transport = try USBTransport(device: device)
      let session = ADBSession(transport: transport, identity: ADBIdentity(store: SpikeKeychainStore()))
      try await session.connect()
      lines.append("握手成功，features 共 \(await session.features.count) 项")
      try await session.open("shell:getprop ro.product.model")
      var output = Data()
      while let chunk = try await session.readChunk() { output.append(chunk) }
      lines.append("型号：\(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
      await session.disconnect()
    } catch {
      lines.append("失败：\(error)")
    }
    return lines.joined(separator: "\n")
  }
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
