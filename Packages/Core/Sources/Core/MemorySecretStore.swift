import Foundation
import Synchronization

/// 演示和测试使用独立内存，不访问系统钥匙串。
public final class MemorySecretStore: SecretStore {
  private let values = Mutex<[String: Data]>([:])

  public init() {}

  public func read(_ key: String) throws -> Data? {
    values.withLock { $0[key] }
  }

  public func write(_ data: Data, for key: String) throws {
    values.withLock { $0[key] = data }
  }

  public func delete(_ key: String) throws {
    values.withLock { _ = $0.removeValue(forKey: key) }
  }
}
