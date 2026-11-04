import Foundation
import Synchronization

/// 待保存值按账号在进程内共享，不另写明文文件；保存失败时保留刷新锁。
public final class RecoverableSecretStore: SecretStore {
  private struct Pending: Sendable {
    let data: Data
    let owner: any SecretStore
    var lease: CredentialRefreshLock?
  }

  private let base: any SecretStore
  private static let pending = Mutex<[URL: Pending]>([:])

  public init(base: any SecretStore) {
    self.base = (base as? RecoverableSecretStore)?.base ?? base
  }

  public func refreshLockLocation(for key: String) -> URL {
    base.refreshLockLocation(for: key)
  }

  public func acquireRefreshLock(for key: String) async throws -> CredentialRefreshLock {
    try await CredentialRefreshLock.acquire(at: refreshLockLocation(for: key)) {
      try self.retryPendingWrite(key)
    }
  }

  public func releaseRefreshLock(_ lease: CredentialRefreshLock, for key: String) {
    Self.pending.withLock { values in
      let location = refreshLockLocation(for: key)
      if values[location] != nil {
        values[location]?.lease = lease
      } else {
        lease.release()
      }
    }
  }

  private func retryPendingWrite(_ key: String) throws {
    try Self.pending.withLock { values in
      let location = refreshLockLocation(for: key)
      guard let value = values[location] else { return }
      try base.write(value.data, for: key)
      values.removeValue(forKey: location)
      value.lease?.release()
    }
  }

  public func read(_ key: String) throws -> Data? {
    try retryPendingWrite(key)
    return try base.read(key)
  }

  public func write(_ data: Data, for key: String) throws {
    try Self.pending.withLock { values in
      let location = refreshLockLocation(for: key)
      let retainedLease = values[location]?.lease
      values[location] = Pending(data: data, owner: base, lease: retainedLease)
      try base.write(data, for: key)
      values.removeValue(forKey: location)
      retainedLease?.release()
    }
  }

  public func delete(_ key: String) throws {
    try Self.pending.withLock { values in
      try base.delete(key)
      values.removeValue(forKey: refreshLockLocation(for: key))?.lease?.release()
    }
  }
}
