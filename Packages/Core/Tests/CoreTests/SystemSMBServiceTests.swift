import Foundation
import Synchronization
import Testing

@testable import Core

private let fixtureConnection = Connection(params: [
  "host": "fixture.invalid", "share": "photos", "username": "fixture", "guest": "true",
])
private func mountEntry(
  id: UInt8 = 1, source: String = "smb://fixture.invalid/photos", capacity: Int64? = nil
) -> SystemSMBService.MountEntry {
  .init(
    type: "smbfs", source: source, path: URL(filePath: "/fixture"), filesystemID: Data([id]),
    availableBytes: capacity)
}

@MainActor @Test func systemMountCapacityUsesFreshMatchingIdentityAndClearsOldCache() async throws {
  let fresh = Mutex<SystemSMBService.MountEntry?>(mountEntry(capacity: 42))
  let entries = Mutex([mountEntry(source: "smb://other.invalid/photos"), mountEntry()])
  var operations = SystemSMBService.Operations()
  operations.entries = { entries.withLock { $0 } }
  operations.capacity = { _ in
    #expect(!Thread.isMainThread)
    return fresh.withLock { $0 }
  }
  let service = SystemSMBService(location: LocalStorageLocation(), operations: operations)
  #expect(service.mounted(fixtureConnection)?.availableBytes == nil)
  #expect(await service.refreshMounted(fixtureConnection)?.availableBytes == 42)
  #expect(service.mounted(fixtureConnection)?.availableBytes == 42)
  entries.withLock { $0 = [mountEntry(id: 2)] }
  #expect(service.mounted(fixtureConnection)?.availableBytes == nil)
  #expect(await service.refreshMounted(fixtureConnection)?.availableBytes == nil)
  fresh.withLock { $0 = mountEntry(id: 2, source: "smb://other.invalid/photos", capacity: 99) }
  #expect(await service.refreshMounted(fixtureConnection)?.availableBytes == nil)
  fresh.withLock { $0 = nil }
  #expect(await service.refreshMounted(fixtureConnection)?.availableBytes == nil)
  entries.withLock { $0 = [] }
  #expect(await service.refreshMounted(fixtureConnection) == nil)
}

@MainActor @Test func systemMountDelegatesCredentialsAndParsesSharesWithoutNetwork() async throws {
  var operations = SystemSMBService.Operations()
  var mounted = false
  var unmounted = false
  operations.mount = { url, user, password, guest, point in
    #expect(url.host == "fixture.invalid")
    #expect(user == "fixture")
    #expect(password == "fixture-password")
    #expect(guest)
    #expect(point == nil)
    mounted = true
    return URL(filePath: "/fixture")
  }
  operations.unmount = {
    #expect($0.path == "/fixture")
    unmounted = true
  }
  operations.shares = { server, password in
    #expect(!Thread.isMainThread)
    #expect(server == "//fixture@fixture.invalid")
    #expect(password == "fixture-password")
    return ("Photos  Disk  files\nPrinter  Printer  device", 0)
  }
  let service = SystemSMBService(location: LocalStorageLocation(), operations: operations)
  #expect(
    try await service.mount(fixtureConnection, password: "fixture-password").path == "/fixture")
  try await service.unmount(URL(filePath: "/fixture"))
  #expect(mounted && unmounted)
  #expect(
    try await service.shares(host: "fixture.invalid", user: "fixture", password: "fixture-password")
      == ["Photos"])
  await #expect(throws: ConnectionError.authentication) {
    try await service.shares(host: "fixture.invalid", user: "fixture", password: "bad\npassword")
  }
  operations.shares = { _, _ in ("authentication failed", 1) }
  let failed = SystemSMBService(location: LocalStorageLocation(), operations: operations)
  await #expect(throws: ConnectionError.authentication) {
    try await failed.shares(host: "fixture.invalid", user: "fixture", password: "fixture-password")
  }
}

@MainActor @Test func systemMountTestNeverRecursivelyDeletesRemoteFiles() async throws {
  let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: home) }
  let location = LocalStorageLocation(home: home)
  for populated in [false, true] {
    var mounted: URL?
    var operations = SystemSMBService.Operations()
    operations.mount = { _, _, _, _, point in
      let point = try #require(point)
      mounted = point
      if populated {
        try Data("remote fixture".utf8).write(to: point.appending(path: "remote.txt"))
      }
      return point
    }
    operations.unmount = { _ in if populated { throw ConnectionError.busy } }
    let service = SystemSMBService(location: location, operations: operations)
    if populated {
      await #expect(throws: ConnectionError.busy) {
        try await service.test(fixtureConnection, password: "")
      }
      #expect(
        try Data(contentsOf: #require(mounted).appending(path: "remote.txt"))
          == Data("remote fixture".utf8))
    } else {
      try await service.test(fixtureConnection, password: "")
      #expect(!FileManager.default.fileExists(atPath: try #require(mounted).path))
    }
  }
  var operations = SystemSMBService.Operations()
  operations.mount = { _, _, _, _, _ in URL(filePath: "/wrong-fixture") }
  let wrong = SystemSMBService(location: location, operations: operations)
  await #expect(throws: ConnectionError.system(EIO)) {
    try await wrong.test(fixtureConnection, password: "")
  }
}

@Test func nativeMountTableReadsOnlyLocalTemporaryFilesystem() throws {
  let path = FileManager.default.temporaryDirectory
  let entry = try #require(NativeMountTable.capacity(path))
  #expect(!entry.filesystemID.isEmpty)
  #expect(entry.availableBytes != nil)
  #expect(NativeMountTable.capacity(path.appending(path: UUID().uuidString)) == nil)
}
