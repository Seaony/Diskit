import Foundation
import Security

public enum SharedStorage {
  public static let appGroup = "JJJKGPY7T7.com.seaony.Diskit"
  public static let keychainGroup = "JJJKGPY7T7.com.seaony.Diskit.shared"

  static var directory: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }
}

public struct SharedStorageLocation: StorageLocation {
  public let dataDirectory: URL
  public let cacheDirectory: URL

  public init() throws {
    guard let directory = SharedStorage.directory else {
      throw StorageMigrationError.containerUnavailable
    }
    dataDirectory = directory
    cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "Diskit", directoryHint: .isDirectory)
  }
}

public struct SharedKeychainStore: SecretStore {
  public let service: String
  public init(service: String = "com.seaony.Diskit") { self.service = service }

  public func refreshLockLocation(for key: String) -> URL {
    // 容器不可用时让锁操作报错，不能退回每个进程各自的锁。
    let directory = SharedStorage.directory ?? URL(filePath: "/dev/null")
    return CredentialRefreshLock.location(
      directory: directory.appending(path: "CredentialLocks"), namespace: service, key: key)
  }

  private func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: key,
      kSecAttrAccessGroup as String: SharedStorage.keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  public func read(_ key: String) throws -> Data? {
    var attributes = query(key)
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = result as? Data else { throw StorageMigrationError.verificationFailed }
    return data
  }

  public func write(_ data: Data, for key: String) throws {
    let attributes = query(key)
    var status = SecItemUpdate(
      attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var insert = attributes
      insert[kSecValueData as String] = data
      status = SecItemAdd(insert as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}
