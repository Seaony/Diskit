import Foundation
import OSLog
import Synchronization

public struct RuntimeStorage: Sendable {
  public let location: any StorageLocation
  public let secrets: any SecretStore
  public let usesSharedStorage: Bool

  private static let selected = Mutex(
    select(
      sharedLocation: { try SharedStorageLocation() }, sharedSecrets: SharedKeychainStore(),
      legacyLocation: LocalStorageLocation(), legacySecrets: LoginKeychainStore()))

  public static var current: RuntimeStorage { selected.withLock { $0 } }

  static var legacy: RuntimeStorage {
    RuntimeStorage(
      location: LocalStorageLocation(), secrets: LoginKeychainStore(), usesSharedStorage: false)
  }

  public static func prepareForApplication() -> Error? {
    let result = prepare(current, migration: { try SharedStorageMigration.run() }, fallback: legacy)
    selected.withLock { $0 = result.storage }
    return result.error
  }

  public static func useLegacyStorage() {
    selected.withLock { $0 = legacy }
  }

  static func prepare(
    _ storage: RuntimeStorage, migration: () throws -> Void, fallback: RuntimeStorage
  ) -> (storage: RuntimeStorage, error: Error?) {
    guard storage.usesSharedStorage else { return (storage, nil) }
    do {
      try migration()
      return (storage, nil)
    } catch {
      return (fallback, error)
    }
  }

  static func select(
    sharedLocation: () throws -> any StorageLocation, sharedSecrets: any SecretStore,
    legacyLocation: any StorageLocation, legacySecrets: any SecretStore
  ) -> RuntimeStorage {
    let logger = Logger(subsystem: "com.seaony.Kayoi", category: "storage")
    do {
      let location = try sharedLocation()
      let identifier = UUID().uuidString
      let file = location.dataDirectory.appending(path: ".storage-access-check-" + identifier)
      let key = "storage-access-check." + identifier
      let data = Data(identifier.utf8)
      defer {
        try? FileManager.default.removeItem(at: file)
        try? sharedSecrets.delete(key)
      }
      try FileManager.default.createDirectory(
        at: location.dataDirectory, withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
      guard try Data(contentsOf: file) == data else {
        throw StorageMigrationError.verificationFailed
      }
      try sharedSecrets.write(data, for: key)
      guard try sharedSecrets.read(key) == data else {
        throw StorageMigrationError.verificationFailed
      }
      logger.info("共享数据目录与钥匙串写入、读回核对通过")
      return RuntimeStorage(location: location, secrets: sharedSecrets, usesSharedStorage: true)
    } catch {
      let value = error as NSError
      if let keychain = error as? KeychainError {
        logger.notice("共享存储不可用，继续使用传统存储：\(value.domain, privacy: .public) OSStatus=\(keychain.status, privacy: .public)")
      } else {
        logger.notice("共享存储不可用，继续使用传统存储：\(value.domain, privacy: .public) code=\(value.code)")
      }
      return RuntimeStorage(
        location: legacyLocation, secrets: legacySecrets, usesSharedStorage: false)
    }
  }
}
