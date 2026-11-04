import Foundation
import Security

public protocol StorageLocation: Sendable {
  var dataDirectory: URL { get }
  var cacheDirectory: URL { get }
}

public struct LocalStorageLocation: StorageLocation {
  public let dataDirectory: URL
  public let cacheDirectory: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    dataDirectory = home.appending(
      path: "Library/Application Support/Kayoi", directoryHint: .isDirectory)
    cacheDirectory = home.appending(path: "Library/Caches/Kayoi", directoryHint: .isDirectory)
  }
}

public struct ConfigurationStore: Sendable {
  private let location: any StorageLocation
  public init(location: any StorageLocation = LocalStorageLocation()) { self.location = location }
  public func read() throws -> Data? {
    let url = location.dataDirectory.appending(path: "connections.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
  public func write(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: location.dataDirectory, withIntermediateDirectories: true)
    try data.write(to: location.dataDirectory.appending(path: "connections.json"), options: .atomic)
  }
  public func delete() throws {
    let url = location.dataDirectory.appending(path: "connections.json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

public protocol SecretStore: Sendable {
  func refreshLockLocation(for key: String) -> URL
  func read(_ key: String) throws -> Data?
  func write(_ data: Data, for key: String) throws
  func delete(_ key: String) throws
}

extension SecretStore {
  public func refreshLockLocation(for key: String) -> URL {
    CredentialRefreshLock.location(
      directory: FileManager.default.temporaryDirectory.appending(path: "Kayoi-CredentialLocks"),
      namespace: String(reflecting: Self.self), key: key)
  }
}

public struct KeychainError: Error, Sendable {
  public let status: OSStatus
}

public struct LoginKeychainStore: SecretStore {
  public let service: String
  public init(service: String = "com.seaony.Kayoi") { self.service = service }
  public func refreshLockLocation(for key: String) -> URL {
    CredentialRefreshLock.location(
      directory: LocalStorageLocation().dataDirectory.appending(path: "CredentialLocks"),
      namespace: service, key: key)
  }
  private func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: key,
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
    return result as? Data
  }
  public func write(_ data: Data, for key: String) throws {
    let attributes = query(key)
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(attributes as CFDictionary, update as CFDictionary)
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

extension StorageLocation {
  var connectionTestDirectory: URL { dataDirectory.appending(path: "ConnectionTests") }
}
