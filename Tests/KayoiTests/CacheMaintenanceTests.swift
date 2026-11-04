import Foundation
import Testing

@Test func cacheSizeIncludesHiddenFilesButNeverFollowsLinks() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let cache = root.appending(path: "cache")
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(repeating: 1, count: 7).write(to: cache.appending(path: ".hidden"))
  let outside = root.appending(path: "outside")
  try Data(repeating: 1, count: 90).write(to: outside)
  try FileManager.default.createSymbolicLink(at: cache.appending(path: "link"), withDestinationURL: outside)
  let maintenance = CacheMaintenance()
  #expect(await maintenance.size(at: cache) == 7)
  try await maintenance.clear(at: cache)
  #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func cacheEvictionRemovesOldestFileFirst() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let old = root.appending(path: "old")
  let new = root.appending(path: "new")
  for url in [old, new] { try Data(repeating: 1, count: 5).write(to: url) }
  try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
  try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: new.path)
  try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: new.path)
  let maintenance = CacheMaintenance()
  try await maintenance.enforceLimit(at: root, bytes: 5)
  #expect(!FileManager.default.fileExists(atPath: old.path))
  #expect(FileManager.default.fileExists(atPath: new.path))
  #expect(await maintenance.size(at: root) == 5)
}

@Test func errorLogAppendsAndRemovesExpiredLogs() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let expired = root.appending(path: "expired.log")
  try Data("old".utf8).write(to: expired)
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let timeZone = try #require(TimeZone(secondsFromGMT: 0))
  try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-8 * 86_400)], ofItemAtPath: expired.path)
  let maintenance = CacheMaintenance()
  try await maintenance.appendError("first", at: date, directory: root, timeZone: timeZone)
  try await maintenance.appendError("second", at: date, directory: root, timeZone: timeZone)
  let text = try String(contentsOf: root.appending(path: LogDate.filename(for: date, timeZone: timeZone)), encoding: .utf8)
  #expect(text.hasPrefix("2023-11-14T22:13:20Z first\n"))
  #expect(text.contains("second\n"))
  #expect(!FileManager.default.fileExists(atPath: expired.path))
}

@Test func cacheMaintenanceDoesNotTraverseLinkedRoot() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let outside = root.appending(path: "outside")
  let linked = root.appending(path: "cache")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = outside.appending(path: "keep")
  try Data("keep".utf8).write(to: file)
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
  let maintenance = CacheMaintenance()
  #expect(await maintenance.size(at: linked) == 0)
  try await maintenance.enforceLimit(at: linked, bytes: 0)
  #expect(FileManager.default.fileExists(atPath: file.path))
}
