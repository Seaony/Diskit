import Foundation
import Testing

@Test func fileSystemCacheMaintenanceCountsAndClearsOnlyReadFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let connection = root.appending(path: UUID().uuidString)
  let read = connection.appending(path: "Read")
  let overlay = connection.appending(path: "Overlay")
  let writes = connection.appending(path: "Writes")
  let other = root.appending(path: "Other/Read")
  let nested = read.appending(path: "Nested")
  for directory in [read, overlay, writes, other, nested] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  let cached = read.appending(path: "cached.data")
  let hidden = read.appending(path: ".download-old")
  try Data(repeating: 1, count: 7).write(to: cached)
  try Data(repeating: 1, count: 3).write(to: hidden)
  let protected = [
    overlay.appending(path: "Xattrs.json"), writes.appending(path: "upload.data"),
    other.appending(path: "keep"), nested.appending(path: "keep"),
  ]
  for file in protected { try Data("keep".utf8).write(to: file) }

  let maintenance = FileSystemCacheMaintenance(root: root)
  #expect(try await maintenance.size() == 10)
  try await maintenance.clear()
  #expect(try await maintenance.size() == 0)
  #expect(!FileManager.default.fileExists(atPath: cached.path))
  #expect(!FileManager.default.fileExists(atPath: hidden.path))
  for file in protected { #expect(try Data(contentsOf: file) == Data("keep".utf8)) }
}

@Test func fileSystemCacheLimitKeepsMetadataAndNewestReadFile() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let connection = root.appending(path: UUID().uuidString)
  let read = connection.appending(path: "Read")
  let writes = connection.appending(path: "Writes")
  try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: writes, withIntermediateDirectories: true)
  let old = read.appending(path: "old")
  let new = read.appending(path: "new")
  let pending = writes.appending(path: "pending")
  try Data(repeating: 1, count: 5).write(to: old)
  try Data(repeating: 1, count: 5).write(to: new)
  try Data(repeating: 1, count: 30).write(to: pending)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: new.path)

  let maintenance = FileSystemCacheMaintenance(root: root)
  try await maintenance.enforceLimit(bytes: 5)
  #expect(try await maintenance.size() == 5)
  #expect(!FileManager.default.fileExists(atPath: old.path))
  #expect(FileManager.default.fileExists(atPath: new.path))
  #expect(try Data(contentsOf: pending).count == 30)
}

@Test func fileSystemCacheMaintenanceRejectsSymbolicRootsAndReadLinks() async throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let outside = base.appending(path: "outside")
  let linkedRoot = base.appending(path: "linked")
  let root = base.appending(path: "root")
  defer { try? FileManager.default.removeItem(at: base) }
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let outsideFile = outside.appending(path: "keep")
  try Data("keep".utf8).write(to: outsideFile)
  try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
  let linked = FileSystemCacheMaintenance(root: linkedRoot)
  await #expect(throws: POSIXError(.ELOOP)) { try await linked.size() }
  await #expect(throws: POSIXError(.ELOOP)) { try await linked.clear() }

  let read = root.appending(path: UUID().uuidString).appending(path: "Read")
  try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
  let link = read.appending(path: "linked.data")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
  let maintenance = FileSystemCacheMaintenance(root: root)
  await #expect(throws: POSIXError(.ELOOP)) { try await maintenance.size() }
  await #expect(throws: POSIXError(.ELOOP)) { try await maintenance.enforceLimit(bytes: 0) }
  await #expect(throws: POSIXError(.ELOOP)) { try await maintenance.clear() }
  #expect(try Data(contentsOf: outsideFile) == Data("keep".utf8))
}

@Test func fileSystemCacheMaintenanceDistinguishesMissingAndUnreadableRoot() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let maintenance = FileSystemCacheMaintenance(root: root)
  #expect(try await maintenance.size() == 0)
  try await maintenance.clear()
  try await maintenance.enforceLimit(bytes: 0)
  try Data("not a directory".utf8).write(to: root)
  await #expect(throws: POSIXError(.ENOTDIR)) { try await maintenance.size() }
  try FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  }
  await #expect(throws: (any Error).self) { try await maintenance.size() }
}
