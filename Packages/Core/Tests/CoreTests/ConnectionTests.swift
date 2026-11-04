import Foundation
import Synchronization
import Testing

@testable import Core

private final class MemorySecrets: SecretStore, Sendable {
  let failWrites = Mutex(false)
  let failDeletes = Mutex(false)
  let deletions = Mutex<[String]>([])
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws {
    if failWrites.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    values.withLock { $0[key] = data }
  }
  func delete(_ key: String) throws {
    deletions.withLock { $0.append(key) }
    if failDeletes.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
    _ = values.withLock { $0.removeValue(forKey: key) }
  }
}

@MainActor private final class FakeSMB: SMBServing {
  var available = ["照片 共享", "Data"]
  var error: ConnectionError?
  var unmountError: ConnectionError?
  var volumes: [UUID: MountedShare] = [:]
  var calls: [String] = []
  var mountedAddresses: [UUID: URL] = [:]
  var onUnmount: ((URL) throws -> Void)?
  func shares(host: String, user: String, password: String) async throws -> [String] {
    calls.append("shares")
    if let error { throw error }
    return available
  }
  func test(_ connection: Connection, password: String) async throws {
    calls.append("test")
    if let error { throw error }
    guard connection.kind != .smb || available.contains(connection.params["share"] ?? "")
    else {
      throw ConnectionError.missingShare
    }
  }
  func mount(_ connection: Connection, password: String) async throws -> URL {
    calls.append("mount")
    if let error { throw error }
    let value = MountedShare(
      url: URL(fileURLWithPath: "/Volumes/" + connection.id.uuidString), availableBytes: 12345)
    volumes[connection.id] = value
    mountedAddresses[connection.id] = try? SystemMountAddress.url(for: connection)
    return value.url
  }
  func unmount(_ url: URL) async throws {
    calls.append("unmount")
    try onUnmount?(url)
    if let unmountError { throw unmountError }
    volumes = volumes.filter { $0.value.url != url }
    mountedAddresses = mountedAddresses.filter { volumes[$0.key] != nil }
  }
  func mounted(_ connection: Connection) -> MountedShare? {
    if let address = mountedAddresses[connection.id],
      address != (try? SystemMountAddress.url(for: connection))
    {
      return nil
    }
    return volumes[connection.id]
  }
}

private func sample(_ name: String = "Windows") -> Connection {
  Connection(
    name: name, params: ["host": "192.0.2.10", "username": "test@example.com", "share": "照片 共享"])
}

@Test func unauthorizedCloudErrorsAskForLogin() {
  let cloudKinds: [ConnectionKind] = [
    .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou,
  ]
  #expect(
    cloudKinds.allSatisfy {
      HumanError.remote(.unauthorized, kind: $0) == "登录已失效，请重新登录"
    })
  #expect(
    cloudKinds.allSatisfy {
      HumanError.remote(.http(401), kind: $0) == "登录已失效，请重新登录"
    })
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

@Test func systemMountURLsCoverSMBWebDAVAndNFS() throws {
  let smb = try SystemMountAddress.url(for: sample())
  #expect(smb.scheme == "smb")
  #expect(smb.host == "192.0.2.10")
  #expect(smb.path == "/照片 共享")

  let webdav = try SystemMountAddress.url(
    for: Connection(
      kind: .webdavHTTPS, name: "Nextcloud",
      params: ["url": "https://cloud.example.com/remote.php/dav/files/alice/"]))
  #expect(webdav.scheme == "https")
  #expect(webdav.host == "cloud.example.com")
  #expect(webdav.path == "/remote.php/dav/files/alice")

  let nfs = try SystemMountAddress.url(
    for: Connection(kind: .nfs, name: "NAS", params: ["host": "nas.local", "path": "/media"]))
  #expect(nfs.scheme == "nfs")
  #expect(nfs.host == "nas.local")
  #expect(nfs.path == "/media")
  #expect(
    SystemMountAddress.matches(
      connection: Connection(
        kind: .nfs, name: "NAS", params: ["host": "nas.local", "path": "/media"]),
      source: "nas.local:/media", type: "nfs"))
  #expect(
    !SystemMountAddress.matches(
      connection: Connection(
        kind: .nfs, name: "NAS", params: ["host": "nas.local", "path": "/media"]),
      source: "nas.local:/other", type: "nfs"))
}

@Test @MainActor func webDAVParticipatesInSaveMountAndAutoMount() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var connection = Connection(
    kind: .webdavHTTPS, name: "Nextcloud", autoMount: true,
    params: ["url": "https://cloud.example.com/dav", "username": "alice"])
  try await manager.save(connection, password: "secret")
  #expect(manager.states[connection.id] == .disconnected)
  await manager.autoMount()
  #expect(manager.mountedCount == 1)
  #expect(f.smb.calls.contains("test"))
  #expect(f.smb.calls.contains("mount"))
  connection.name = "Company files"
  try await manager.save(connection, password: "secret")
  #expect(f.smb.volumes[connection.id] != nil)
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

@Test @MainActor func genericCameraRemovalClearsConnectionTestResult() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .cameraUSB, name: "相机", params: ["serial": "camera-usb"])
  manager.cameraUSBDevicesChanged(serials: ["camera-usb"])
  manager.testRemote = { _ in SpaceInfo(total: 0, used: 0) }
  try await manager.save(connection, password: "")
  manager.cameraUSBDevicesChanged(serials: [])
  #expect(manager.states[connection.id] == .disconnected)
  #expect(f.smb.calls.isEmpty)
}

@Test @MainActor func remoteSecretIsAvailableDuringTestAndRestoredOnFailure() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(
    kind: .s3, name: "S3",
    params: ["endpoint": "https://s3.example.com", "bucket": "bucket", "accessKey": "key"])
  manager.testRemote = { tested in
    let saved = try manager.savedPassword(tested)
    #expect(saved == "new-secret")
    throw RemoteError.posix(EACCES)
  }
  await #expect(throws: RemoteError.posix(EACCES)) {
    try await manager.save(connection, password: "new-secret")
  }
  #expect(try manager.savedPassword(connection) == "")

  manager.testRemote = { tested in
    let saved = try manager.savedPassword(tested)
    #expect(saved == "new-secret")
    return SpaceInfo(total: 100, used: 10)
  }
  try await manager.save(connection, password: "new-secret")
  #expect(try manager.savedPassword(connection) == "new-secret")
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

@Test @MainActor func deletingQuarkConnectionRemovesCookieWithoutTouchingOtherSecrets() async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .quark, name: "夸克", params: ["nickname": "测试账号"])
  try f.secrets.write(Data("cookie".utf8), for: "\(connection.id.uuidString).cookie")
  try f.secrets.write(Data("other-account".utf8), for: "another.cookie")
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 10) }
  try await manager.save(connection, password: "")
  try await manager.remove(connection)
  #expect(try f.secrets.read("\(connection.id.uuidString).cookie") == nil)
  #expect(try f.secrets.read("another.cookie") == Data("other-account".utf8))
}

@Test @MainActor func deletingOfficialCloudRemovesItsOAuthToken() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(
    kind: .oneDrive, name: "OneDrive", params: ["nickname": "测试账号"])
  let tokenKey = "\(connection.id.uuidString).oauth.oneDrive"
  try f.secrets.write(Data("token".utf8), for: tokenKey)
  try f.secrets.write(Data("other-token".utf8), for: "another.oauth.oneDrive")
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 10) }
  try await manager.save(connection, password: "")
  try await manager.remove(connection)
  #expect(try f.secrets.read(tokenKey) == nil)
  #expect(try f.secrets.read("another.oauth.oneDrive") == Data("other-token".utf8))
}

@Test @MainActor func connectionFailuresLogOnceWithoutExtraMountNotifications() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var logged: [String] = []
  var notified: [String] = []
  manager.operationFailed = { logged.append($0) }
  manager.mountFailed = { notified.append($0) }
  let remote = Connection(kind: .androidUSB, name: "手机")
  manager.testRemote = { _ in throw RemoteError.occupied }
  await #expect(throws: RemoteError.occupied) { try await manager.save(remote, password: "") }
  await manager.toggle(remote)
  #expect(logged == Array(repeating: RemoteError.occupied.localizedDescription, count: 2))
  #expect(notified.isEmpty)
  let smb = sample()
  f.smb.error = .authentication
  await #expect(throws: ConnectionError.authentication) {
    try await manager.save(smb, password: "secret")
  }
  await #expect(throws: ConnectionError.authentication) {
    try await manager.listShares(host: "host", user: "user", password: "secret")
  }
  await manager.toggle(smb)
  #expect(logged.count == 5)
  #expect(notified.count == 1)
  f.smb.error = nil
  try await manager.save(smb, password: "secret")
  await manager.toggle(smb)
  f.smb.unmountError = .busy
  await manager.toggle(smb)
  await #expect(throws: ConnectionError.busy) { try await manager.remove(smb) }
  #expect(logged.count == 7)
  #expect(logged.suffix(2) == Array(repeating: ConnectionError.busy.localizedDescription, count: 2))
  #expect(notified.count == 1)
}

@Test @MainActor func connectionLogsNeverIncludeUnknownErrorDetails() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var logged: [String] = []
  manager.operationFailed = { logged.append($0) }
  manager.testRemote = { _ in
    throw NSError(
      domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
      userInfo: [
        NSLocalizedDescriptionKey:
          "https://secret.example/?token=secret Cookie=secret password=secret"
      ])
  }
  await manager.toggle(Connection(kind: .quark, name: "含敏感信息的名称"))
  #expect(logged == [ConnectionError.timeout.localizedDescription])
  manager.reportOperationError(
    NSError(
      domain: NSPOSIXErrorDomain, code: Int(EACCES),
      userInfo: [NSLocalizedDescriptionKey: "token=secret"]))
  manager.reportOperationError(
    NSError(domain: "unknown", code: 99, userInfo: [NSLocalizedDescriptionKey: "Cookie=secret"]))
  manager.reportOperationError(CancellationError())
  #expect(
    logged == [
      ConnectionError.timeout.localizedDescription, RemoteError.posix(EACCES).localizedDescription,
      RemoteError.posix(EIO).localizedDescription,
    ])
}

@Test @MainActor func webDriveAuthenticationFailureAsksForLogin() async {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .mobileCloud, name: "移动云盘")
  var expired: [UUID] = []
  manager.loginExpired = { expired.append($0.id) }
  manager.testRemote = { _ in
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
  }

  await manager.toggle(connection)

  #expect(manager.states[connection.id] == .needsLogin)
  #expect(expired == [connection.id])
}

@Test(arguments: [ConnectionKind.aliyunDrive, .oneDrive])
@MainActor func deletingConnectionClearsPendingRefreshedCredentials(kind: ConnectionKind)
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(
    kind: kind, name: "网盘", params: ["nickname": "测试账号", "userID": "user"])
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 10) }
  try await manager.save(connection, password: "")
  let key = connection.id.uuidString + (kind == .aliyunDrive ? ".oauth" : ".oauth.\(kind.rawValue)")
  let sessionStore = RecoverableSecretStore(base: f.secrets)
  f.secrets.failWrites.withLock { $0 = true }
  #expect(throws: CocoaError.self) { try sessionStore.write(Data("rotated".utf8), for: key) }
  f.secrets.failWrites.withLock { $0 = false }
  try await manager.remove(connection)
  #expect(try sessionStore.read(key) == nil)
  #expect(try f.secrets.read(key) == nil)
}

@Test(arguments: [
  ConnectionKind.smb, .aliyunDrive, .quark, .ucDrive, .baiduDrive, .drive115, .drive123, .oneDrive,
  .googleDrive, .dropbox, .pikPak, .tianyiDrive,
])
@MainActor func removalSaveFailurePreservesCredentialsAndCache(kind: ConnectionKind) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 10) }
  let connection =
    kind == .smb ? sample() : Connection(kind: kind, name: "网盘", params: ["nickname": "测试账号"])
  try await manager.save(connection, password: "password")
  if kind == .smb { await manager.toggle(connection) }
  let prefix = connection.id.uuidString
  let keys = [
    connection.passwordKey, prefix + ".oauth", prefix + ".cookie",
    prefix + ".oauth." + kind.rawValue,
  ]
  for key in keys { try f.secrets.write(Data("saved".utf8), for: key) }
  let cache = f.location.cacheDirectory.appending(path: prefix)
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  let cachedFile = cache.appending(path: "cached")
  try Data("cached data".utf8).write(to: cachedFile)
  let config = f.location.dataDirectory.appending(path: "connections.json")
  let backup = f.location.dataDirectory.appending(path: "saved.json")
  try FileManager.default.moveItem(at: config, to: backup)
  try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
  try Data().write(to: config.appending(path: "block-write"))
  await #expect(throws: CocoaError.self) { try await manager.remove(connection) }
  #expect(manager.connections.contains { $0.id == connection.id })
  #expect(f.secrets.deletions.withLock { $0.isEmpty })
  for key in keys { #expect(try f.secrets.read(key) == Data("saved".utf8)) }
  #expect(try Data(contentsOf: cachedFile) == Data("cached data".utf8))
  if kind == .smb {
    #expect(f.smb.mounted(connection) == nil)
    #expect(manager.states[connection.id] == .disconnected)
  }
  try FileManager.default.removeItem(at: config)
  try FileManager.default.moveItem(at: backup, to: config)
  #expect(try ConnectionRepository(location: f.location).load().map(\.id) == [connection.id])
}

@Test @MainActor func removalCleanupFailureKeepsPublishedConfigurationConsistent() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "saved")
  f.secrets.failDeletes.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { try await manager.remove(connection) }
  #expect(manager.connections.isEmpty)
  #expect(manager.states[connection.id] == nil)
  #expect(try ConnectionRepository(location: f.location).load().isEmpty)
  #expect(try f.secrets.read(connection.passwordKey) == Data("saved".utf8))
  f.secrets.failDeletes.withLock { $0 = false }
  try await manager.remove(connection)
  #expect(try f.secrets.read(connection.passwordKey) == nil)
}

private func mountedEditConnection(_ kind: ConnectionKind) -> Connection {
  switch kind {
  case .smb: return sample()
  case .webdav, .webdavHTTPS:
    return Connection(
      kind: kind, name: "WebDAV",
      params: [
        "url": "\(kind == .webdav ? "http" : "https")://192.0.2.10/share", "username": "user",
      ])
  default:
    return Connection(kind: .nfs, name: "NFS", params: ["host": "192.0.2.10", "path": "/share"])
  }
}

@Test(arguments: [ConnectionKind.smb, .webdav, .webdavHTTPS, .nfs], [false, true])
@MainActor func editingMountedAddressEjectsBeforeSaving(kind: ConnectionKind, ejectFails: Bool)
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let original = mountedEditConnection(kind)
  try await manager.save(original, password: "old")
  await manager.toggle(original)
  let volume = try #require(f.smb.volumes[original.id])
  var unexpected = 0
  manager.unexpectedDisconnect = { _ in unexpected += 1 }
  f.smb.onUnmount = { (url: URL) throws -> Void in
    #expect(url == volume.url)
    #expect(try ConnectionRepository(location: f.location).load().first?.params == original.params)
    #expect(try manager.savedPassword(original) == "old")
  }
  if ejectFails { f.smb.unmountError = .busy }
  var edited = original
  edited.params = edited.params.mapValues {
    $0.replacingOccurrences(of: "192.0.2.10", with: "192.0.2.20")
  }
  if ejectFails {
    await #expect(throws: ConnectionError.busy) { try await manager.save(edited, password: "new") }
    #expect(manager.connections.first?.params == original.params)
    #expect(try ConnectionRepository(location: f.location).load().first?.params == original.params)
    #expect(try manager.savedPassword(original) == "old")
    #expect(f.smb.volumes[original.id] != nil)
  } else {
    try await manager.save(edited, password: "new")
    #expect(f.smb.volumes[original.id] == nil)
    #expect(manager.states[original.id] == .disconnected)
    #expect(try ConnectionRepository(location: f.location).load().first?.params == edited.params)
    #expect(try manager.savedPassword(edited) == "new")
  }
  #expect(f.smb.calls == ["test", "mount", "test", "unmount"])
  manager.refreshMounts()
  #expect(unexpected == 0)
}

@Test @MainActor func editingOnlyMountedNameKeepsVolume() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var connection = sample()
  try await manager.save(connection, password: "old")
  await manager.toggle(connection)
  connection.name = "新名称"
  connection.color = "red"
  try await manager.save(connection, password: "old")
  #expect(f.smb.volumes[connection.id] != nil)
  #expect(!f.smb.calls.contains("unmount"))
}

@Test @MainActor func mountedEditSaveFailureRestoresCredentialsWithoutFalseDisconnectNotice()
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let original = sample()
  try await manager.save(original, password: "old")
  await manager.toggle(original)
  var unexpected = 0
  manager.unexpectedDisconnect = { _ in unexpected += 1 }
  let config = f.location.dataDirectory.appending(path: "connections.json")
  let backup = f.location.dataDirectory.appending(path: "saved.json")
  f.smb.onUnmount = { _ in
    try FileManager.default.moveItem(at: config, to: backup)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
    try Data().write(to: config.appending(path: "block-write"))
  }
  var edited = original
  edited.params["host"] = "192.0.2.20"
  await #expect(throws: CocoaError.self) { try await manager.save(edited, password: "new") }
  #expect(manager.connections.first?.params == original.params)
  #expect(try manager.savedPassword(original) == "old")
  #expect(f.smb.volumes[original.id] == nil)
  #expect(manager.states[original.id] == .disconnected)
  manager.refreshMounts()
  #expect(unexpected == 0)
  try FileManager.default.removeItem(at: config)
  try FileManager.default.moveItem(at: backup, to: config)
  #expect(try ConnectionRepository(location: f.location).load().first?.params == original.params)
}
