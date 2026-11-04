import Core
import Foundation
import Synchronization

public final class TestSecretStore: SecretStore, Sendable {
  public let nextRead = Mutex<AsyncStream<Void>.Continuation?>(nil)
  public let failWrites = Mutex(false)
  public let values = Mutex<[String: Data]>([:])

  public init() {}

  public func read(_ key: String) throws -> Data? {
    let value = values.withLock { $0[key] }
    nextRead.withLock { observer in
      observer?.yield(())
      observer?.finish()
      observer = nil
    }
    return value
  }

  public func write(_ data: Data, for key: String) throws {
    if failWrites.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    values.withLock { $0[key] = data }
  }

  public func delete(_ key: String) throws {
    _ = values.withLock { $0.removeValue(forKey: key) }
  }

  public func string(_ key: String) throws -> String? {
    try read(key).map { String(decoding: $0, as: UTF8.self) }
  }
}
