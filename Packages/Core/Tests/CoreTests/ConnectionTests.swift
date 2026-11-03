import Foundation
import Synchronization
import Testing

@testable import Core

private final class MemorySecrets: SecretStore, Sendable {
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

@MainActor private final class FakeSMB: SMBServing {
  var available = ["照片 共享", "Data"]
  var error: ConnectionError?
  var unmountError: ConnectionError?
  var volumes: [UUID: MountedShare] = [:]
  var calls: [String] = []
  func shares(host: String, user: String, password: String) async throws -> [String] {
    calls.append("shares")
    if let error { throw error }
    return available
  }
  func test(_ connection: Connection, password: String) async throws {
    calls.append("test")
    if let error { throw error }
    guard available.contains(connection.params["share"] ?? "") else {
      throw ConnectionError.missingShare
    }
  }
  func mount(_ connection: Connection, password: String) async throws -> URL {
    calls.append("mount")
    if let error { throw error }
    let value = MountedShare(
      url: URL(fileURLWithPath: "/Volumes/" + connection.id.uuidString), availableBytes: 12345)
    volumes[connection.id] = value
    return value.url
  }
  func unmount(_ url: URL) async throws {
    calls.append("unmount")
    if let unmountError { throw unmountError }
    volumes = volumes.filter { $0.value.url != url }
  }
  func mounted(_ connection: Connection) -> MountedShare? { volumes[connection.id] }
}

private func sample(_ name: String = "Windows") -> Connection {
  Connection(
    name: name, params: ["host": "192.0.2.10", "username": "test@example.com", "share": "照片 共享"])
}

@MainActor private struct Fixture {
  let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let smb = FakeSMB()
  let secrets = MemorySecrets()
  var location: LocalStorageLocation { LocalStorageLocation(home: home) }
  func manager() -> ConnectionManager {
    ConnectionManager(location: location, secrets: secrets, smb: smb)
  }
  func clean() { try? FileManager.default.removeItem(at: home) }
}

@Test @MainActor func rejectsWrongPasswordBeforeSaving() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  f.smb.error = .authentication
  await #expect(throws: ConnectionError.authentication) {
    try await manager.save(sample(), password: "wrong")
  }
  #expect(manager.connections.isEmpty)
  #expect(try ConnectionRepository(location: f.location).load().isEmpty)
  #expect(f.secrets.values.withLock { $0.isEmpty })
  #expect(ConnectionError.authentication.errorDescription == "用户名或密码错误")
}

@Test @MainActor func rejectsMissingShareAndInvalidFields() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var connection = sample()
  connection.params["share"] = "Missing"
  await #expect(throws: ConnectionError.missingShare) {
    try await manager.save(connection, password: "pass")
  }
  connection.name = " "
  await #expect(throws: ConnectionError.invalidFields) {
    try await manager.save(connection, password: "pass")
  }
  #expect(f.smb.calls == ["test"])
  #expect(manager.connections.isEmpty)
}

@Test @MainActor func editSortAndRestartPreserveConfiguration() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var a = sample("A")
  let b = sample("B")
  try await manager.save(a, password: "first-secret")
  try await manager.save(b, password: "second-secret")
  a.name = "修改名称"
  a.color = "green"
  a.autoMount = true
  try await manager.save(a, password: "new-secret")
  try manager.reorder(b.id, before: a.id)
  let restarted = f.manager()
  #expect(restarted.connections.map(\.name) == ["B", "修改名称"])
  #expect(restarted.connections.map(\.order) == [0, 1])
  #expect(restarted.connections.last?.autoMount == true)
  #expect(try restarted.savedPassword(a) == "new-secret")
  let raw = try #require(try ConfigurationStore(location: f.location).read())
  #expect(!String(decoding: raw, as: UTF8.self).contains("secret"))
}

@Test @MainActor func removalUnmountsAndDeletesSecretsAndCache() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let a = sample()
  try await manager.save(a, password: "pass")
  await manager.toggle(a)
  let cache = f.location.cacheDirectory.appending(path: a.id.uuidString)
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  try Data([1]).write(to: cache.appending(path: "cached"))
  try await manager.remove(a)
  #expect(f.smb.calls == ["test", "mount", "unmount"])
  #expect(try f.secrets.read(a.passwordKey) == nil)
  #expect(!FileManager.default.fileExists(atPath: cache.path))
  #expect(try ConnectionRepository(location: f.location).load().isEmpty)
  #expect(manager.states[a.id] == nil)
}

@Test @MainActor func failedUnmountKeepsConnectionAndSecret() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let a = sample()
  try await manager.save(a, password: "pass")
  await manager.toggle(a)
  f.smb.unmountError = .busy
  await #expect(throws: ConnectionError.busy) { try await manager.remove(a) }
  #expect(manager.connections.count == 1)
  #expect(try manager.savedPassword(a) == "pass")
}

@Test @MainActor func startupMountsOnlyEnabledUnMountedConnections() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var enabled = sample("自动")
  enabled.autoMount = true
  let disabled = sample("手动")
  try await manager.save(enabled, password: "pass")
  try await manager.save(disabled, password: "pass")
  let restarted = f.manager()
  var opened: [URL] = []
  restarted.openInFinder = { opened.append($0) }
  await restarted.autoMount()
  await restarted.autoMount()
  #expect(f.smb.calls.filter { $0 == "mount" }.count == 1)
  #expect(opened.count == 1)
  #expect(restarted.mountedCount == 1)
  f.smb.volumes.removeAll()
  restarted.refreshMounts()
  #expect(restarted.states[enabled.id] == .disconnected)
}

@Test @MainActor func mountFailureCanRetryAndReportsOnce() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let a = sample()
  try await manager.save(a, password: "pass")
  var errors: [String] = []
  manager.mountFailed = { errors.append($0) }
  f.smb.error = .timeout
  await manager.toggle(a)
  #expect(errors.count == 1)
  #expect(manager.states[a.id] == .failed(ConnectionError.timeout.localizedDescription))
  f.smb.error = nil
  await manager.toggle(a)
  #expect(manager.mountedCount == 1)
  await manager.toggle(a)
  #expect(manager.states[a.id] == .disconnected)
}

@Test @MainActor func futureConfigIsNotOverwritten() async throws {
  let f = Fixture()
  defer { f.clean() }
  let original = Data(#"{"version":99,"connections":[]}"#.utf8)
  try ConfigurationStore(location: f.location).write(original)
  let manager = f.manager()
  #expect(manager.loadError != nil)
  await #expect(throws: ConnectionError.unsupportedVersion) {
    try await manager.save(sample(), password: "pass")
  }
  #expect(try ConfigurationStore(location: f.location).read() == original)
}

@Test func smbURLKeepsCredentialsOutOfMountURL() throws {
  let url = try SMBAddress.url(host: "192.0.2.10", user: "a@example.com", share: "照片 共享")
  let parsed = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  #expect(parsed.user == "a@example.com")
  #expect(parsed.path == "/照片 共享")
  #expect(parsed.password == nil)
  #expect(throws: ConnectionError.invalidFields) { try SMBAddress.url(host: "host/share") }
}

@Test func shareParsingKeepsSpacesAndFiltersNonDiskTypes() throws {
  let output = """
    Share                                           Type    Comments
    -------------------------------
    照片 共享                                      Disk    Photos
    Data                                            Disk
    IPC$                                            Pipe    IPC
    Printer                                         Printer Office
    4 shares listed
    """
  #expect(try SMBAddress.parseShares(output, exitStatus: 0) == ["照片 共享", "Data"])
  #expect(throws: ConnectionError.authentication) {
    try SMBAddress.parseShares("smbutil: server rejected the authentication", exitStatus: 77)
  }
  #expect(throws: ConnectionError.timeout) {
    try SMBAddress.parseShares("Operation timed out", exitStatus: 1)
  }
  #expect(ConnectionError.status(EAUTH) == .authentication)
}

@Test @MainActor func testingExistingConnectionDoesNotUnmountIt() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var a = sample()
  try await manager.save(a, password: "pass")
  await manager.toggle(a)
  let volume = f.smb.volumes[a.id]
  a.name = "新名称"
  try await manager.save(a, password: "pass")
  #expect(f.smb.volumes[a.id] == volume)
  #expect(!f.smb.calls.contains("unmount"))
  f.smb.error = .authentication
  await #expect(throws: ConnectionError.authentication) {
    try await manager.save(a, password: "wrong")
  }
  #expect(f.smb.volumes[a.id] == volume)
  #expect(try manager.savedPassword(a) == "pass")
}

@Test @MainActor func nonSMBTestsNeverMountAndUnplugWinsOverLateResult() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .androidUSB, name: "手机", params: ["serial": "serial"])
  manager.usbDevicesChanged(serials: ["serial"])
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 20) }
  try await manager.save(connection, password: "")
  #expect(manager.states[connection.id] == .tested(SpaceInfo(total: 100, used: 20)))
  #expect(f.smb.calls.isEmpty)
  manager.testRemote = { _ in
    manager.usbDevicesChanged(serials: [])
    throw RemoteError.notConnected
  }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .disconnected)
  manager.usbDevicesChanged(serials: ["serial"])
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 20) }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .tested(SpaceInfo(total: 100, used: 20)))
}

@Test @MainActor func wirelessRediscoveryKeepsSavedGUIDAndLateFailureStaysDisconnected()
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let guid = "adb-serial-Ab123Z"
  let connection = Connection(kind: .androidWiFi, name: "无线手机", params: ["guid": guid])
  manager.wirelessGUIDsChanged([guid])
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 20) }
  try await manager.save(connection, password: "")
  manager.testRemote = { _ in
    manager.wirelessGUIDsChanged([])
    throw RemoteError.notConnected
  }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .disconnected)
  manager.wirelessGUIDsChanged([guid])
  manager.testRemote = { _ in SpaceInfo(total: 200, used: 20) }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .tested(SpaceInfo(total: 200, used: 20)))
  #expect(try ConnectionRepository(location: f.location).load().first?.params == ["guid": guid])
  #expect(f.smb.calls.isEmpty)
}

@Test @MainActor func cameraRemovalClearsConnectionTestResult() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .ricohGR, name: "GR IV", params: ["serial": "camera"])
  manager.ricohDevicesChanged(serials: ["camera"])
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 20) }
  try await manager.save(connection, password: "")
  manager.ricohDevicesChanged(serials: [])
  #expect(manager.states[connection.id] == .disconnected)
  #expect(f.smb.calls.isEmpty)
  #expect(try manager.savedPassword(connection) == "")
}

@Test @MainActor func cloudLoginFailureKeepsReloginStateAndRemovalDeletesOnlyItsSecret()
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(
    kind: .aliyunDrive, name: "网盘", params: ["nickname": "测试账号", "userID": "user"])
  try f.secrets.write(Data("authorization".utf8), for: "\(connection.id.uuidString).oauth")
  try f.secrets.write(Data("global-key".utf8), for: "adb.private-key")
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 10) }
  try await manager.save(connection, password: "")
  manager.testRemote = { _ in
    manager.requireLogin(connection.id)
    throw RemoteError.posix(EACCES)
  }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .needsLogin)
  try await manager.remove(connection)
  #expect(try f.secrets.read("\(connection.id.uuidString).oauth") == nil)
  #expect(try f.secrets.read("adb.private-key") == Data("global-key".utf8))
}
