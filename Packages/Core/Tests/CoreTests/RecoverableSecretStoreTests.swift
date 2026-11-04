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
