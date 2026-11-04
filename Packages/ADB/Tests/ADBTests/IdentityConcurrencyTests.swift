import Core
import Foundation
import Testing

@testable import ADB

@Test func concurrentFirstIdentityUsesOneStoredKey() async throws {
  let store = MemorySecretStore()
  let keys = try await withThrowingTaskGroup(of: Data.self) { group in
    for _ in 0..<8 {
      group.addTask { try ADBIdentity(store: store).publicKeyData() }
    }
    var result: [Data] = []
    for try await key in group { result.append(key) }
    return result
  }
  #expect(Set(keys).count == 1)
  #expect(try ADBIdentity(store: store).publicKeyData() == keys.first)
}
