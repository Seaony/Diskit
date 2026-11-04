import Foundation
import Synchronization

/// 写入失败时只在内存保留新值，读取前重试保存，不另写明文文件。
public final class RecoverableSecretStore: SecretStore {
  private let base: any SecretStore
  private let pending = Mutex<[String: Data]>([:])

  public init(base: any SecretStore) { self.base = base }

  public func read(_ key: String) throws -> Data? {
    try pending.withLock { values in
      if let data = values[key] {
        try base.write(data, for: key)
        values.removeValue(forKey: key)
        return data
      }
      return try base.read(key)
    }
  }

  public func write(_ data: Data, for key: String) throws {
    try pending.withLock { values in
      values[key] = data
      try base.write(data, for: key)
      values.removeValue(forKey: key)
    }
  }

  public func delete(_ key: String) throws {
    try pending.withLock { values in
      try base.delete(key)
      values.removeValue(forKey: key)
    }
  }
}
