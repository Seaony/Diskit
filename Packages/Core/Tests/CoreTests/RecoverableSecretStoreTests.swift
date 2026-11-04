import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Core

private final class FailingSecretStore: SecretStore {
  let base = MemorySecretStore()
  let fails = Mutex(false)
  func read(_ key: String) throws -> Data? { try base.read(key) }
  func write(_ data: Data, for key: String) throws {
    if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    try base.write(data, for: key)
  }
  func delete(_ key: String) throws {
    if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    try base.delete(key)
  }
}

@Test func failedSecretWriteRemainsPendingUntilSaved() throws {
  let base = FailingSecretStore()
  let store = RecoverableSecretStore(base: base)
  try base.write(Data("old".utf8), for: "account")
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try store.write(Data("new".utf8), for: "account") }
  #expect(try base.read("account") == Data("old".utf8))
  #expect(throws: CocoaError.self) { _ = try store.read("account") }
  base.fails.withLock { $0 = false }
  #expect(try store.read("account") == Data("new".utf8))
  #expect(try base.read("account") == Data("new".utf8))
  try base.write(Data("external".utf8), for: "account")
  #expect(try store.read("account") == Data("external".utf8))
}

@Test func explicitDeletionClearsPendingWriteOnlyAfterSuccess() throws {
  let base = FailingSecretStore()
  let store = RecoverableSecretStore(base: base)
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try store.write(Data("new".utf8), for: "account") }
  #expect(throws: CocoaError.self) { try store.delete("account") }
  base.fails.withLock { $0 = false }
  #expect(try store.read("account") == Data("new".utf8))
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try store.write(Data("pending".utf8), for: "account") }
  base.fails.withLock { $0 = false }
  try store.delete("account")
  #expect(try store.read("account") == nil)
  #expect(try base.read("account") == nil)
}

@Test func failedWriteIsSharedBetweenStoreWrappers() throws {
  let base = FailingSecretStore()
  let first = RecoverableSecretStore(base: base)
  let second = RecoverableSecretStore(base: base)
  try base.write(Data("old".utf8), for: "account")
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try first.write(Data("new".utf8), for: "account") }
  #expect(throws: CocoaError.self) { _ = try second.read("account") }
  base.fails.withLock { $0 = false }
  #expect(try second.read("account") == Data("new".utf8))
  #expect(try first.read("account") == Data("new".utf8))
}

@Test(arguments: [false, true])
func pendingSecretRetainsProcessLockUntilSavedOrDeleted(delete: Bool) async throws {
  let base = FailingSecretStore()
  let first = RecoverableSecretStore(base: base)
  let second = RecoverableSecretStore(base: base)
  let url = first.refreshLockLocation(for: "account")
  defer { try? FileManager.default.removeItem(at: url) }
  let lease = try await first.acquireRefreshLock(for: "account")
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try first.write(Data("new".utf8), for: "account") }
  first.releaseRefreshLock(lease, for: "account")
  #expect(try probeLockInChild(url) == 7)
  #expect(throws: CocoaError.self) { _ = try second.read("account") }
  #expect(try probeLockInChild(url) == 7)
  base.fails.withLock { $0 = false }
  if delete {
    try second.delete("account")
    #expect(try first.read("account") == nil)
  } else {
    #expect(try second.read("account") == Data("new".utf8))
  }
  #expect(try probeLockInChild(url) == 0)
}

@Test func refreshWaiterRetriesPendingWriteAndReportsStorageFailure() async throws {
  let base = FailingSecretStore()
  let first = RecoverableSecretStore(base: base)
  let second = RecoverableSecretStore(base: base)
  let url = first.refreshLockLocation(for: "account")
  defer { try? FileManager.default.removeItem(at: url) }
  let lease = try await first.acquireRefreshLock(for: "account")
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try first.write(Data("new".utf8), for: "account") }
  first.releaseRefreshLock(lease, for: "account")
  await #expect(throws: CocoaError.self) { _ = try await second.acquireRefreshLock(for: "account") }
  base.fails.withLock { $0 = false }
  let next = try await second.acquireRefreshLock(for: "account")
  #expect(try base.read("account") == Data("new".utf8))
  #expect(try probeLockInChild(url) == 7)
  second.releaseRefreshLock(next, for: "account")
  #expect(try probeLockInChild(url) == 0)
}

@Test func pendingSecretsDoNotCrossStoreInstancesOrAccountKeys() throws {
  let firstBase = FailingSecretStore()
  let secondBase = FailingSecretStore()
  let first = RecoverableSecretStore(base: firstBase)
  let second = RecoverableSecretStore(base: secondBase)
  firstBase.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try first.write(Data("first".utf8), for: "account") }
  #expect(try second.read("account") == nil)
  #expect(try first.read("other") == nil)
  firstBase.fails.withLock { $0 = false }
  let nested = RecoverableSecretStore(base: first)
  #expect(try nested.read("account") == Data("first".utf8))
}

@Test func refreshWaitTimeoutPreservesPendingCredentialAndOwnerLock() async throws {
  let base = FailingSecretStore()
  let store = RecoverableSecretStore(base: base)
  let url = store.refreshLockLocation(for: "account")
  defer { try? FileManager.default.removeItem(at: url) }
  try base.write(Data("old".utf8), for: "account")
  let owner = try await store.acquireRefreshLock(for: "account")
  base.fails.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try store.write(Data("rotated".utf8), for: "account") }
  store.releaseRefreshLock(owner, for: "account")
  let clock = ManualTestClock()
  let waiting = Task {
    try await CredentialRefreshLock.acquire(
      at: url, deadline: clock.now.advanced(by: .seconds(30)), clock: clock.deadlineClock)
  }
  defer { waiting.cancel() }
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  do {
    let waiter = try await waiting.value
    waiter.release()
    Issue.record("等待失败保存的凭据时应超时")
  } catch let error as POSIXError {
    #expect(error.code == .ETIMEDOUT)
  }
  #expect(try probeLockInChild(url) == 7)
  #expect(try base.read("account") == Data("old".utf8))
  base.fails.withLock { $0 = false }
  #expect(try store.read("account") == Data("rotated".utf8))
  #expect(try probeLockInChild(url) == 0)
  try store.delete("account")
}
