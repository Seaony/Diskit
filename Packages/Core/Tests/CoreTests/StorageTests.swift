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

@Test func loginKeychainLifecycle() throws {
  let store = LoginKeychainStore(service: "com.seaony.Kayoi.tests.\(UUID().uuidString)")
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
