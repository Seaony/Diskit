import Foundation
import Testing

@testable import Core

@MainActor private final class FileSystemMountService: SMBServing {
  var volumes: [UUID: MountedShare] = [:]
  var parameters: [UUID: [String: String]] = [:]
  var mountedIDs: [UUID] = []
  var unmountedURLs: [URL] = []
  var unmountFailure: Error?

  func seed(_ connection: Connection) -> MountedShare {
    let volume = MountedShare(url: URL(fileURLWithPath: "/Volumes/" + connection.id.uuidString))
    volumes[connection.id] = volume
    parameters[connection.id] = connection.params
    return volume
  }
  func shares(host: String, user: String, password: String) async throws -> [String] { [] }
  func test(_ connection: Connection, password: String) async throws {}
  func mount(_ connection: Connection, password: String) async throws -> URL {
    mountedIDs.append(connection.id)
    return seed(connection).url
  }
  func unmount(_ url: URL) async throws {
    if let unmountFailure { throw unmountFailure }
    unmountedURLs.append(url)
    volumes = volumes.filter { $0.value.url != url }
  }
  func mounted(_ connection: Connection) -> MountedShare? {
    guard parameters[connection.id] == connection.params else { return nil }
    return volumes[connection.id]
  }
}

@MainActor private struct FileSystemMountFixture {
  let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let service = FileSystemMountService()
  let secrets = MemorySecretStore()
  var location: LocalStorageLocation { LocalStorageLocation(home: home) }

  func manager(connections: [Connection] = []) throws -> ConnectionManager {
    try ConnectionRepository(location: location).save(connections)
    return ConnectionManager(location: location, secrets: secrets, smb: service)
  }
  func clean() { try? FileManager.default.removeItem(at: home) }
}

@Test @MainActor func fileSystemAutoMountAndDeviceConnectionAreIdempotentWithoutTestingAgain()
  async throws
{
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  let cloud = Connection(kind: .quark, name: "网盘", autoMount: true)
  let phone = Connection(
    kind: .androidUSB, name: "手机", autoMount: true, params: ["serial": "phone"])
  let manual = Connection(kind: .s3, name: "手动位置")
  let camera = Connection(kind: .ricohGR, name: "GR", autoMount: true)
  let manager = try fixture.manager(connections: [cloud, phone, manual, camera])
  var tests = 0
  manager.testRemote = { _ in
    tests += 1
    return SpaceInfo(total: 10, used: 1)
  }
  await manager.autoMount()
  await manager.autoMount()
  await manager.connectIfNeeded(phone)
  #expect(Set(fixture.service.mountedIDs) == [cloud.id, phone.id])
  #expect(fixture.service.mountedIDs.count == 2)
  #expect(fixture.service.unmountedURLs.isEmpty)
  #expect(manager.mountedCount == 2)
  #expect(tests == 0)
}

@Test @MainActor func fileSystemQuitEjectsOnlyOwnedNonSMBVolumesAndKeepsExistingVolumes()
  async throws
{
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  let preexisting = Connection(kind: .quark, name: "原有卷")
  let phone = Connection(kind: .androidUSB, name: "手机")
  let webdav = Connection(kind: .webdavHTTPS, name: "WebDAV")
  let smb = Connection(kind: .smb, name: "系统共享")
  let manager = try fixture.manager(connections: [preexisting, phone, webdav, smb])
  let existingVolume = fixture.service.seed(preexisting)
  await manager.connectIfNeeded(preexisting)
  await manager.connectIfNeeded(phone)
  await manager.connectIfNeeded(webdav)
  await manager.connectIfNeeded(smb)
  let owned = try [phone, webdav].map { try #require(fixture.service.mounted($0)).url }
  try await manager.ejectOwnedVolumes()
  #expect(Set(fixture.service.unmountedURLs) == Set(owned))
  #expect(fixture.service.mounted(preexisting) == existingVolume)
  #expect(fixture.service.mounted(smb) != nil)
  #expect(fixture.service.mounted(phone) == nil)
  #expect(fixture.service.mounted(webdav) == nil)
  try await manager.ejectOwnedVolumes()
  #expect(fixture.service.unmountedURLs.count == 2)
}

@Test @MainActor
func fileSystemMountedEditCannotChangeConfigurationOrSecretBeforeSuccessfulEjection() async throws {
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  let original = Connection(kind: .s3, name: "对象存储", params: ["bucket": "old"])
  let manager = try fixture.manager()
  var tests = 0
  manager.testRemote = { _ in
    tests += 1
    return SpaceInfo(total: nil, used: nil)
  }
  try await manager.save(original, password: "old-secret")
  await manager.connectIfNeeded(original)
  let volume = try #require(fixture.service.mounted(original))
  let stored = try ConfigurationStore(location: fixture.location).read()
  fixture.service.unmountFailure = ConnectionError.busy
  var edited = original
  edited.params["bucket"] = "new"
  await #expect(throws: ConnectionError.busy) {
    try await manager.save(edited, password: "new-secret")
  }
  #expect(try ConfigurationStore(location: fixture.location).read() == stored)
  #expect(try manager.savedPassword(original) == "old-secret")
  #expect(manager.connections == [original])
  #expect(fixture.service.mounted(original) == volume)
  #expect(tests == 1)
}

@Test @MainActor func fileSystemMountedPresentationEditReusesVolumeWithTheSameStoredPassword()
  async throws
{
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  var connection = Connection(kind: .s3, name: "原名称", params: ["bucket": "bucket"])
  let manager = try fixture.manager()
  var tests = 0
  manager.testRemote = { _ in
    tests += 1
    return SpaceInfo(total: nil, used: nil)
  }
  try await manager.save(connection, password: "same-secret")
  await manager.connectIfNeeded(connection)
  let volume = try #require(fixture.service.mounted(connection))
  connection.name = "新名称"
  connection.color = "red"
  try await manager.save(connection, password: "same-secret")
  #expect(tests == 1)
  #expect(fixture.service.unmountedURLs.isEmpty)
  #expect(fixture.service.mounted(connection) == volume)
  #expect(manager.states[connection.id] == .mounted(volume))
  #expect(manager.connections.first?.name == "新名称")
}

@Test @MainActor func fileSystemLoginRequiredStateSurvivesMountAndCapacityRefresh() async throws {
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  let connection = Connection(kind: .quark, name: "网盘", autoMount: true)
  let manager = try fixture.manager(connections: [connection])
  let volume = fixture.service.seed(connection)
  manager.refreshMounts()
  #expect(manager.states[connection.id] == .mounted(volume))
  manager.requireLogin(connection.id)
  manager.refreshMounts()
  await manager.refreshMountSpace()
  await manager.autoMount()
  #expect(manager.states[connection.id] == .needsLogin)
  fixture.service.volumes.removeValue(forKey: connection.id)
  manager.refreshMounts()
  #expect(manager.states[connection.id] == .needsLogin)
  #expect(fixture.service.mountedIDs.isEmpty)
}

@Test @MainActor
func fileSystemDeviceDisappearanceEjectsOnceAndWiFiReturnReconnectsWithoutToggling() async throws {
  let fixture = FileSystemMountFixture()
  defer { fixture.clean() }
  let guid = "adb-phone-local"
  let phone = Connection(kind: .androidWiFi, name: "无线手机", autoMount: true, params: ["guid": guid])
  let manager = try fixture.manager(connections: [phone])
  var connections: [Task<Void, Never>] = []
  var ejections: [Task<Void, Never>] = []
  var notices = 0
  manager.unexpectedDisconnect = { _ in notices += 1 }
  manager.deviceReturned = { connection in
    connections.append(Task { await manager.connectIfNeeded(connection) })
  }
  manager.deviceDisappeared = { connection in
    ejections.append(Task { await manager.eject(connection) })
  }
  manager.wirelessGUIDsChanged([guid])
  try #require(connections.count == 1)
  await connections[0].value
  manager.wirelessGUIDsChanged([guid])
  #expect(connections.count == 1)
  manager.wirelessGUIDsChanged([])
  manager.wirelessGUIDsChanged([])
  try #require(ejections.count == 1)
  await ejections[0].value
  #expect(manager.states[phone.id] == .disconnected)
  #expect(fixture.service.mounted(phone) == nil)
  #expect(notices == 1)
  manager.wirelessGUIDsChanged([guid])
  try #require(connections.count == 2)
  await connections[1].value
  #expect(fixture.service.mountedIDs == [phone.id, phone.id])
  #expect(fixture.service.unmountedURLs.count == 1)
  #expect(fixture.service.mounted(phone) != nil)
}
