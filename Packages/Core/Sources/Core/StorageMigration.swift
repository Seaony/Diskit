import CryptoKit
import Foundation
import OSLog

private struct PendingMigration: Codable {
  var files: [String: Set<String>] = [:]
  var secrets: [String: Set<String>] = [:]

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum StorageMigrationError: Error, LocalizedError {
  case containerUnavailable, destinationConflict, verificationFailed
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .containerUnavailable: L("无法访问共享数据，请重新构建并签名 Diskit。旧数据未删除。")
    case .destinationConflict: L("新旧存储中有不同的数据，已停止迁移。请保留两处数据并检查日志。")
    case .verificationFailed: L("迁移后的数据核对失败，旧数据已保留。请重新打开 Diskit 重试。")
    case .failed(let detail): LF("数据迁移没有完成，尚未清理的旧数据已保留。请重新打开 Diskit 重试。\n%@", detail)
    }
  }
}

public struct StorageMigration: Sendable {
  let source: any StorageLocation
  let destination: any StorageLocation
  let oldSecrets: any SecretStore
  let newSecrets: any SecretStore
  let secretKeys: [String]
  static let marker = "storage-migration-v1.json"
  private let logger = Logger(subsystem: "com.seaony.Diskit", category: "storage-migration")

  public init(
    source: any StorageLocation, destination: any StorageLocation,
    oldSecrets: any SecretStore, newSecrets: any SecretStore, secretKeys: [String]
  ) {
    self.source = source
    self.destination = destination
    self.oldSecrets = oldSecrets
    self.newSecrets = newSecrets
    self.secretKeys = secretKeys
  }

  public func run() throws {
    let manager = FileManager.default
    let marker = destination.dataDirectory.appending(path: Self.marker)
    if manager.fileExists(atPath: marker.path) { return }
    do {
      // 先确认配置能读，避免把损坏或新版配置当作空列表。
      _ = try ConnectionRepository(location: source).load()
      let journalURL = destination.dataDirectory.appending(
        path: "storage-migration-pending-v1.json")
      var journal =
        manager.fileExists(atPath: journalURL.path)
        ? try JSONDecoder().decode(PendingMigration.self, from: Data(contentsOf: journalURL))
        : PendingMigration()
      func saveJournal() throws {
        try manager.createDirectory(
          at: destination.dataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
      }
      var files: [(old: URL, new: URL, data: Data)] = []
      let configuration = source.dataDirectory.appending(path: "connections.json")
      if manager.fileExists(atPath: configuration.path) {
        files.append(
          (
            configuration, destination.dataDirectory.appending(path: "connections.json"),
            try Data(contentsOf: configuration)
          ))
      }
      let logs = source.dataDirectory.appending(path: "Logs")
      if manager.fileExists(atPath: logs.path) {
        let names = try manager.subpathsOfDirectory(atPath: logs.path)
        for name in names {
          let old = logs.appending(path: name)
          let values = try old.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          guard values.isSymbolicLink != true else {
            throw StorageMigrationError.verificationFailed
          }
          if values.isRegularFile == true {
            files.append(
              (
                old, destination.dataDirectory.appending(path: "Logs").appending(path: name),
                try Data(contentsOf: old)
              ))
          }
        }
      }
      for file in files {
        let name = String(file.new.path.dropFirst(destination.dataDirectory.path.count))
        let existing =
          manager.fileExists(atPath: file.new.path) ? try Data(contentsOf: file.new) : nil
        // 回退旧存储后用户可能继续修改，只更新上次迁移留下且未被另改的副本。
        if let existing, existing != file.data,
          !(journal.files[name] ?? []).contains(PendingMigration.digest(existing))
        {
          throw StorageMigrationError.destinationConflict
        }
        journal.files[name, default: []].insert(PendingMigration.digest(file.data))
        try saveJournal()
        if existing != file.data {
          try manager.createDirectory(
            at: file.new.deletingLastPathComponent(), withIntermediateDirectories: true)
          try file.data.write(to: file.new, options: .atomic)
        }
        guard try Data(contentsOf: file.new) == file.data else {
          throw StorageMigrationError.verificationFailed
        }
      }
      _ = try ConnectionRepository(location: destination).load()
      var secrets: [(key: String, data: Data)] = []
      for key in secretKeys {
        guard let data = try oldSecrets.read(key) else { continue }
        let existing = try newSecrets.read(key)
        if let existing, existing != data,
          !(journal.secrets[key] ?? []).contains(PendingMigration.digest(existing))
        {
          throw StorageMigrationError.destinationConflict
        }
        journal.secrets[key, default: []].insert(PendingMigration.digest(data))
        try saveJournal()
        if existing != data {
          try newSecrets.write(data, for: key)
        }
        guard try newSecrets.read(key) == data else {
          throw StorageMigrationError.verificationFailed
        }
        secrets.append((key, data))
      }
      // 所有文件和钥匙都核对成功，才进入清理阶段。
      for file in files {
        guard try Data(contentsOf: file.old) == file.data,
          try Data(contentsOf: file.new) == file.data
        else { throw StorageMigrationError.verificationFailed }
      }
      for secret in secrets {
        guard try oldSecrets.read(secret.key) == secret.data,
          try newSecrets.read(secret.key) == secret.data
        else { throw StorageMigrationError.verificationFailed }
      }
      try manager.createDirectory(at: destination.dataDirectory, withIntermediateDirectories: true)
      try Data("{\"version\":1}".utf8).write(to: marker, options: .atomic)
      try? manager.removeItem(at: journalURL)
      // 完成标记也写好才清理，避免磁盘已满时删了旧数据却不能继续启动。
      for secret in secrets {
        do { try oldSecrets.delete(secret.key) } catch {
          logger.error("共享数据已验证，旧钥匙条目未清理：\(error.localizedDescription, privacy: .public)")
        }
      }
      for file in files {
        do { try manager.removeItem(at: file.old) } catch {
          logger.error("共享数据已验证，旧文件未清理：\(error.localizedDescription, privacy: .public)")
        }
      }
      logger.info("迁移核对通过：文件 \(files.count)，钥匙串条目 \(secrets.count)")
    } catch {
      let value = error as NSError
      logger.error("迁移停止：\(value.domain, privacy: .public) code=\(value.code)，尚未清理的旧数据保留")
      throw error
    }
  }
}

public enum SharedStorageMigration {
  public static func isComplete(in location: any StorageLocation) -> Bool {
    FileManager.default.fileExists(
      atPath: location.dataDirectory.appending(path: StorageMigration.marker).path)
  }

  public static func run() throws {
    let storage = RuntimeStorage.current
    guard storage.usesSharedStorage else { return }
    let destination = storage.location
    if FileManager.default.fileExists(
      atPath: destination.dataDirectory.appending(path: StorageMigration.marker).path)
    {
      return
    }
    do {
      let oldSecrets = LoginKeychainStore()
      try StorageMigration(
        source: LocalStorageLocation(), destination: destination,
        oldSecrets: oldSecrets, newSecrets: storage.secrets, secretKeys: oldSecrets.keys()
      ).run()
    } catch {
      throw StorageMigrationError.failed(error.localizedDescription)
    }
  }

  public static func prepareForCommandLine() {
    let storage = RuntimeStorage.current
    guard storage.usesSharedStorage else { return }
    let destination = storage.location
    if !FileManager.default.fileExists(
      atPath: destination.dataDirectory.appending(path: StorageMigration.marker).path)
    {
      RuntimeStorage.useLegacyStorage()
    }
  }
}
