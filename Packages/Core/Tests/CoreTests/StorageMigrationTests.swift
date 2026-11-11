import CoreTestSupport
import Foundation
import Testing

@testable import Core

private struct MigrationLocation: StorageLocation {
  let dataDirectory: URL
  var cacheDirectory: URL { dataDirectory.appending(path: "Caches") }
}

private struct MigrationFixture {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  var old: MigrationLocation { MigrationLocation(dataDirectory: root.appending(path: "old")) }
  var shared: MigrationLocation { MigrationLocation(dataDirectory: root.appending(path: "shared")) }
  let source = TestSecretStore()
  let target = TestSecretStore()

  func seed() throws {
    try ConnectionRepository(location: old).save([Connection(name: "保留的位置")])
    let logs = old.dataDirectory.appending(path: "Logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data("原日志".utf8).write(to: logs.appending(path: "day.log"))
    try source.write(Data("原钥匙".utf8), for: "adb.private-key")
    try source.write(Data("原令牌".utf8), for: "account.oauth")
  }

  func migrate() throws {
    try StorageMigration(
      source: old, destination: shared, oldSecrets: source, newSecrets: target,
      secretKeys: ["adb.private-key", "account.oauth"]
    ).run()
  }
}

@Test func storageMigrationCopiesVerifiesThenRemovesLegacyData() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  let original = try ConfigurationStore(location: fixture.old).read()
  try fixture.migrate()
  #expect(try ConfigurationStore(location: fixture.shared).read() == original)
  #expect(try fixture.target.read("adb.private-key") == Data("原钥匙".utf8))
  #expect(try fixture.target.read("account.oauth") == Data("原令牌".utf8))
  #expect(try fixture.source.read("adb.private-key") == nil)
  #expect(try fixture.source.read("account.oauth") == nil)
  #expect(try ConfigurationStore(location: fixture.old).read() == nil)
  #expect(
    try Data(contentsOf: fixture.shared.dataDirectory.appending(path: "Logs/day.log"))
      == Data("原日志".utf8))
}

@Test func partialMigrationKeepsAllLegacyDataAndCanResume() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  fixture.target.failWrites.withLock { $0 = true }
  #expect(throws: (any Error).self) { try fixture.migrate() }
  #expect(try ConfigurationStore(location: fixture.old).read() != nil)
  #expect(try fixture.source.read("adb.private-key") == Data("原钥匙".utf8))
  #expect(try fixture.source.read("account.oauth") == Data("原令牌".utf8))
  fixture.target.failWrites.withLock { $0 = false }
  try fixture.migrate()
  #expect(try fixture.target.read("account.oauth") == Data("原令牌".utf8))
}

@Test func repeatedMigrationPreservesNewConfigurationAndRefreshedSecrets() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  try fixture.migrate()
  try ConnectionRepository(location: fixture.shared).save([Connection(name: "迁移后的位置")])
  try fixture.target.write(Data("刷新令牌".utf8), for: "account.oauth")
  try fixture.migrate()
  #expect(try ConnectionRepository(location: fixture.shared).load().first?.name == "迁移后的位置")
  #expect(try fixture.target.read("account.oauth") == Data("刷新令牌".utf8))
}

@Test func migrationNeverOverwritesDifferentDestinationData() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  try fixture.target.write(Data("另一把钥匙".utf8), for: "adb.private-key")
  #expect(throws: (any Error).self) { try fixture.migrate() }
  #expect(try fixture.source.read("adb.private-key") == Data("原钥匙".utf8))
  #expect(try fixture.target.read("adb.private-key") == Data("另一把钥匙".utf8))
  #expect(try ConfigurationStore(location: fixture.old).read() != nil)
}

@Test func unavailableSharedKeychainKeepsLegacyConfigurationAndIdentity() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  let original = try ConfigurationStore(location: fixture.old).read()
  fixture.target.failWrites.withLock { $0 = true }
  let storage = RuntimeStorage.select(
    sharedLocation: { fixture.shared }, sharedSecrets: fixture.target,
    legacyLocation: fixture.old, legacySecrets: fixture.source)
  #expect(!storage.usesSharedStorage)
  #expect(storage.location.dataDirectory == fixture.old.dataDirectory)
  #expect(try ConfigurationStore(location: storage.location).read() == original)
  #expect(try storage.secrets.read("adb.private-key") == Data("原钥匙".utf8))
  #expect(try ConfigurationStore(location: fixture.old).read() == original)
  #expect(try ConfigurationStore(location: fixture.shared).read() == nil)
}

@Test func unavailableSharedDirectoryKeepsLegacyStorage() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  let blocked = fixture.root.appending(path: "not-a-directory")
  try Data("file".utf8).write(to: blocked)
  let storage = RuntimeStorage.select(
    sharedLocation: { MigrationLocation(dataDirectory: blocked) }, sharedSecrets: fixture.target,
    legacyLocation: fixture.old, legacySecrets: fixture.source)
  #expect(!storage.usesSharedStorage)
  #expect(try ConnectionRepository(location: storage.location).load().first?.name == "保留的位置")
  #expect(try fixture.source.read("adb.private-key") == Data("原钥匙".utf8))
}

@Test func usableSharedStoragePassesWriteAndReadbackWithoutMigratingDuringSelection() throws {
  let fixture = MigrationFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.seed()
  let storage = RuntimeStorage.select(
    sharedLocation: { fixture.shared }, sharedSecrets: fixture.target,
    legacyLocation: fixture.old, legacySecrets: fixture.source)
  #expect(storage.usesSharedStorage)
  #expect(storage.location.dataDirectory == fixture.shared.dataDirectory)
  #expect(try fixture.source.read("adb.private-key") == Data("原钥匙".utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.shared.dataDirectory.path).isEmpty)
  #expect(fixture.target.values.withLock { $0.isEmpty })
}
