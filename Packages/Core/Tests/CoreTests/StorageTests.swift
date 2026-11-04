import Foundation
import Testing

@testable import Core

@Test func configurationLifecycle() throws {
  let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: home) }
  let location = LocalStorageLocation(home: home)
  #expect(
    location.dataDirectory.path == home.appending(path: "Library/Application Support/Kayoi").path)
  #expect(location.cacheDirectory.path == home.appending(path: "Library/Caches/Kayoi").path)
  let store = ConfigurationStore(location: location)
  #expect(try store.read() == nil)
  try store.write(Data("first".utf8))
  #expect(try store.read() == Data("first".utf8))
  try store.write(Data("second".utf8))
  #expect(try store.read() == Data("second".utf8))
  try store.delete()
  #expect(try store.read() == nil)
  try store.delete()
}

@Test func memorySecretLifecycle() throws {
  let store = MemorySecretStore()
  let key = "test.secret"
  defer { try? store.delete(key) }
  #expect(try store.read(key) == nil)
  try store.write(Data("first".utf8), for: key)
  #expect(try store.read(key) == Data("first".utf8))
  try store.write(Data("second".utf8), for: key)
  #expect(try store.read(key) == Data("second".utf8))
  try store.delete(key)
  #expect(try store.read(key) == nil)
  try store.delete(key)
}

@Test func clearingCacheCannotReachConnectionTestContents() throws {
  let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: home) }
  let location = LocalStorageLocation(home: home)
  let mountPoint = location.connectionTestDirectory.appending(path: "connection")
  try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: location.cacheDirectory, withIntermediateDirectories: true)
  let marker = mountPoint.appending(path: "remote-content")
  try Data("keep".utf8).write(to: marker)
  try FileManager.default.removeItem(at: location.cacheDirectory)
  #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func memorySecretsAreIsolatedBetweenRuns() throws {
  let first = MemorySecretStore()
  let second = MemorySecretStore()
  try first.write(Data("demo".utf8), for: "token")
  #expect(try second.read("token") == nil)
}
