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
  var mountFailure: (any Error)?
  var volumes: [UUID: MountedShare] = [:]
  var calls: [String] = []
  var mountedAddresses: [UUID: URL] = [:]
  var onUnmount: ((URL) throws -> Void)?
  var onMount: ((Connection) async -> Void)?
  var refreshVolume: ((Connection) async -> MountedShare?)?
  var mountedConnections: [Connection] = []
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
    mountedConnections.append(connection)
    await onMount?(connection)
    if let mountFailure { throw mountFailure }
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
  func refreshMounted(_ connection: Connection) async -> MountedShare? {
    if let refreshVolume { return await refreshVolume(connection) }
    return mounted(connection)
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
      HumanError.remote(.unauthorized, kind: $0) == L("登录已失效，请重新登录")
    })
  #expect(
    cloudKinds.allSatisfy {
      HumanError.remote(.http(401), kind: $0) == L("登录已失效，请重新登录")
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
  #expect(ConnectionError.authentication.errorDescription == L("用户名或密码错误"))
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

@Test @MainActor func androidSaveTestsWithoutMountingAndToggleUsesMountService() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .androidUSB, name: "手机", params: ["serial": "serial"])
  manager.usbDevicesChanged(serials: ["serial"])
  var tests = 0
  manager.testRemote = { _ in
    tests += 1
    return SpaceInfo(total: 100, used: 20)
  }
  try await manager.save(connection, password: "")
  #expect(manager.states[connection.id] == .tested(SpaceInfo(total: 100, used: 20)))
  #expect(f.smb.calls.isEmpty)
  f.smb.onMount = { _ in manager.usbDevicesChanged(serials: []) }
  f.smb.mountFailure = RemoteError.notConnected
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .disconnected)
  manager.usbDevicesChanged(serials: ["serial"])
  f.smb.onMount = nil
  f.smb.mountFailure = nil
  await manager.toggle(connection)
  let mounted = try #require(f.smb.volumes[connection.id])
  #expect(manager.states[connection.id] == .mounted(mounted))
  #expect(f.smb.calls == ["mount", "mount"])
  #expect(tests == 1)
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
  f.smb.onMount = { _ in manager.wirelessGUIDsChanged([]) }
  f.smb.mountFailure = RemoteError.notConnected
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .disconnected)
  manager.wirelessGUIDsChanged([guid])
  f.smb.onMount = nil
  f.smb.mountFailure = nil
  await manager.toggle(connection)
  let mounted = try #require(f.smb.volumes[connection.id])
  #expect(manager.states[connection.id] == .mounted(mounted))
  #expect(try ConnectionRepository(location: f.location).load().first?.params == ["guid": guid])
  #expect(f.smb.calls == ["mount", "mount"])
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
  f.smb.onMount = { _ in manager.requireLogin(connection.id) }
  f.smb.mountFailure = RemoteError.posix(EACCES)
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

@Test @MainActor func connectionFailuresLogOnceAndOnlyMountAttemptsNotify() async throws {
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
  f.smb.mountFailure = RemoteError.occupied
  await manager.toggle(remote)
  #expect(logged.map(firstLine) == Array(repeating: RemoteError.occupied.localizedDescription, count: 2))
  #expect(notified.count == 1)
  f.smb.mountFailure = nil
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
  #expect(notified.count == 2)
  f.smb.error = nil
  try await manager.save(smb, password: "secret")
  await manager.toggle(smb)
  f.smb.unmountError = .busy
  await manager.toggle(smb)
  await #expect(throws: ConnectionError.busy) { try await manager.remove(smb) }
  #expect(logged.count == 7)
  #expect(logged.suffix(2).map(firstLine) == Array(repeating: ConnectionError.busy.localizedDescription, count: 2))
  #expect(notified.count == 2)
}

private func firstLine(_ value: String) -> String {
  String(value.split(separator: "\n", omittingEmptySubsequences: false)[0])
}

@Test @MainActor func connectionLogsKeepTheFullErrorChain() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var logged: [String] = []
  manager.operationFailed = { logged.append($0) }
  let underlying = NSError(
    domain: "IOUSBHostErrorDomain", code: -536_870_199,
    userInfo: [NSLocalizedDescriptionKey: "Failed to create IOUSBHostInterface."])
  manager.reportOperationError(
    NSError(
      domain: "unknown", code: 99,
      userInfo: [NSLocalizedDescriptionKey: "outer reason", NSUnderlyingErrorKey: underlying]))
  manager.reportOperationError(RemoteError.failed(EIO, "phone said no"))
  manager.reportOperationError(CancellationError())
  #expect(logged.count == 2)
  #expect(firstLine(logged[0]) == "outer reason")
  #expect(logged[0].contains("unknown 99: outer reason"))
  #expect(logged[0].contains("IOUSBHostErrorDomain -536870199 (0xe00002c9): Failed to create IOUSBHostInterface."))
  #expect(firstLine(logged[1]) == "phone said no")
  #expect(logged[1].contains("RemoteError.failed errno 5: phone said no"))
}

@Test(arguments: [EIO, EBUSY, ENOTCONN])
@MainActor func cardsAndNotificationsUseTheUnderlyingHumanReason(code: Int32) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                        userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code)!)])
  var logged: [String] = []
  var notified: [String] = []
  manager.operationFailed = { logged.append($0) }
  manager.mountFailed = { notified.append($0) }
  f.smb.mountFailure = failure
  await manager.toggle(connection)
  let message = HumanError.posix(code)
  #expect(manager.states[connection.id] == .failed(message))
  #expect(manager.detailedErrors[connection.id] == "\(message) (errno \(code))")
  #expect(logged.map(firstLine) == ["\(message) (errno \(code))"])
  #expect(logged[0].contains("NSCocoaErrorDomain \(NSFileReadUnknownError)"))
  #expect(notified == [message])

  f.smb.mountFailure = nil
  await manager.toggle(connection)
  f.smb.onUnmount = { _ in throw failure }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .failed(message))
  #expect(manager.detailedErrors[connection.id] == "\(message) (errno \(code))")
  #expect(logged.map(firstLine) == Array(repeating: "\(message) (errno \(code))", count: 2))
  #expect(notified == [message])
}

private struct ActionableMountFailure: Error, LocalizedError {
  var errorDescription: String? { "Sign in to the service again." }
}

@Test @MainActor func cardsAndNotificationsKeepUnrelatedServiceAdvice() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  let failure = ActionableMountFailure()
  f.smb.mountFailure = failure
  var logged: [String] = []
  var notified: [String] = []
  manager.operationFailed = { logged.append($0) }
  manager.mountFailed = { notified.append($0) }
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == .failed(failure.localizedDescription))
  #expect(manager.detailedErrors[connection.id] == failure.localizedDescription)
  #expect(notified == [failure.localizedDescription])
  #expect(logged.map(firstLine) == [failure.localizedDescription])
}

@Test @MainActor func webDriveAuthenticationFailureAsksForLogin() async {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .mobileCloud, name: "移动云盘")
  var expired: [UUID] = []
  manager.loginExpired = { expired.append($0.id) }
  f.smb.mountFailure = ExplicitLoginFailure(requiresLogin: true)

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
  var removed: [UUID] = []
  manager.removed = { removed.append($0) }
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
  #expect(removed.isEmpty)
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
  var removed: [UUID] = []
  manager.removed = { removed.append($0) }
  let connection = sample()
  try await manager.save(connection, password: "saved")
  f.secrets.failDeletes.withLock { $0 = true }
  await #expect(throws: CocoaError.self) { try await manager.remove(connection) }
  #expect(removed == [connection.id])
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

@Test @MainActor func explicitEjectNeverMountsAnAlreadyGoneVolume() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.eject(connection)
  #expect(!f.smb.calls.contains("mount"))
  await manager.toggle(connection)
  await manager.eject(connection)
  await manager.eject(connection)
  #expect(f.smb.calls.filter { $0 == "mount" }.count == 1)
  #expect(f.smb.calls.filter { $0 == "unmount" }.count == 1)
  #expect(manager.states[connection.id] == .disconnected)
}

@Test @MainActor func explicitEjectFailureKeepsVolumeAvailableForRetry() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  f.smb.unmountError = .busy
  await manager.eject(connection)
  #expect(f.smb.mounted(connection) != nil)
  #expect(manager.detailedErrors[connection.id] != nil)
  f.smb.unmountError = nil
  await manager.eject(connection)
  #expect(f.smb.mounted(connection) == nil)
  #expect(f.smb.calls.filter { $0 == "mount" }.count == 1)
}

@Test @MainActor func saveFailureWithEmptyPasswordKeepsExistingCredential() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  var connection = Connection(kind: .s3, name: "original")
  try await manager.save(connection, password: "original-secret")
  let config = f.location.dataDirectory.appending(path: "connections.json")
  try FileManager.default.removeItem(at: config)
  try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
  try Data().write(to: config.appending(path: "block-write"))
  connection.name = "edited"
  await #expect(throws: CocoaError.self) { try await manager.save(connection, password: "") }
  #expect(try f.secrets.read(connection.passwordKey) == Data("original-secret".utf8))
  #expect(f.secrets.deletions.withLock { $0.isEmpty })
  #expect(manager.connections.first?.name == "original")
}

@Test @MainActor func credentialRollbackFailureDoesNotReplaceConfigurationError() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  var connection = Connection(kind: .s3, name: "original")
  try await manager.save(connection, password: "original-secret")
  let config = f.location.dataDirectory.appending(path: "connections.json")
  try FileManager.default.removeItem(at: config)
  try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
  try Data().write(to: config.appending(path: "block-write"))
  connection.name = "edited"
  var expected: NSError?
  do { try ConnectionRepository(location: f.location).save([connection]) } catch {
    expected = error as NSError
  }
  let configurationError = try #require(expected)
  manager.testRemote = { _ in
    f.secrets.failWrites.withLock { $0 = true }
    return SpaceInfo(total: 10, used: 1)
  }
  do {
    try await manager.save(connection, password: "new-secret")
    Issue.record("配置写入失败应向调用方报错")
  } catch {
    let failure = error as NSError
    #expect(failure.domain == configurationError.domain)
    #expect(failure.code == configurationError.code)
  }
  let detail = try #require(manager.detailedErrors[connection.id])
  #expect(detail.contains(HumanError.detail(configurationError, kind: .s3)))
  #expect(detail.contains(HumanError.detail(CocoaError(.fileWriteNoPermission), kind: .s3)))
  #expect(manager.connections.first?.name == "original")
  f.secrets.failWrites.withLock { $0 = false }
}

@Test @MainActor func cancelledConnectionTestCannotSaveLateResult() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  var connection = Connection(kind: .s3, name: "original")
  try await manager.save(connection, password: "original-secret")
  var completion: CheckedContinuation<SpaceInfo, Never>?
  manager.testRemote = { _ in
    await withCheckedContinuation { completion = $0 }
  }
  connection.name = "edited"
  let task = Task { try await manager.save(connection, password: "new-secret") }
  while completion == nil { await Task.yield() }
  task.cancel()
  completion?.resume(returning: SpaceInfo(total: 100, used: 2))
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(try f.secrets.read(connection.passwordKey) == Data("original-secret".utf8))
  #expect(manager.connections.first?.name == "original")
  #expect(try ConnectionRepository(location: f.location).load().first?.name == "original")
}

@Test @MainActor func clearingSharePasswordRollsBackWhenConfigurationCannotBeSaved() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  let connection = Connection(kind: .lanzou, name: "share", params: ["authMode": "share"])
  try await manager.save(connection, password: "original-password")
  let config = f.location.dataDirectory.appending(path: "connections.json")
  try FileManager.default.removeItem(at: config)
  try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
  try Data().write(to: config.appending(path: "block-write"))
  manager.testRemote = { _ in
    let storedPassword = try f.secrets.read(connection.passwordKey)
    #expect(storedPassword == nil)
    return SpaceInfo(total: 10, used: 1)
  }
  await #expect(throws: CocoaError.self) {
    try await manager.save(connection, password: "", clearPassword: true)
  }
  #expect(try f.secrets.read(connection.passwordKey) == Data("original-password".utf8))
}

@Test @MainActor func explicitlyClearingSharePasswordIsPersistedAfterSuccessfulTest() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  let connection = Connection(kind: .lanzou, name: "share", params: ["authMode": "share"])
  try await manager.save(connection, password: "original-password")
  try await manager.save(connection, password: "", clearPassword: true)
  #expect(try f.secrets.read(connection.passwordKey) == nil)
  #expect(try ConnectionRepository(location: f.location).load().first?.id == connection.id)
}

@Test(arguments: [URLError.Code.serverCertificateUntrusted, .dataNotAllowed])
@MainActor func networkPermissionFailureDoesNotRequireLogin(code: URLError.Code) async {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .mobileCloud, name: "test")
  var expired = false
  manager.loginExpired = { _ in expired = true }
  f.smb.mountFailure = NetworkFailure.posix(URLError(code))
  await manager.toggle(connection)
  #expect(!expired)
  guard case .failed = manager.states[connection.id] else {
    Issue.record("网络权限或证书错误应显示操作失败")
    return
  }
}

private struct ExplicitLoginFailure: LoginRequiredFailure {
  let requiresLogin: Bool
}

@Test @MainActor func resourcePermissionErrorsDoNotRequireLogin() async {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let errors: [any Error] = [
    RemoteError.http(403), RemoteError.posix(EACCES), RemoteError.posix(EPERM),
    NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
    ExplicitLoginFailure(requiresLogin: false),
  ]
  var expired = false
  manager.loginExpired = { _ in expired = true }
  for error in errors {
    let connection = Connection(kind: .mobileCloud, name: "test")
    f.smb.mountFailure = error
    await manager.toggle(connection)
    #expect(!expired)
    guard case .failed = manager.states[connection.id] else {
      Issue.record("资源权限错误不应要求重新登录")
      continue
    }
  }
}

@Test @MainActor func normalSystemUnmountDoesNotReportUnexpectedDisconnect() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  let mounted = try #require(f.smb.mounted(connection))
  var notices = 0
  manager.unexpectedDisconnect = { _ in notices += 1 }
  f.smb.volumes.removeValue(forKey: connection.id)
  manager.systemVolumeUnmounted(at: mounted.url)
  manager.refreshMounts()
  #expect(notices == 0)
  #expect(manager.states[connection.id] == .disconnected)
  await manager.toggle(connection)
  f.smb.volumes.removeValue(forKey: connection.id)
  manager.refreshMounts()
  manager.refreshMounts()
  #expect(notices == 1)
}

@Test(arguments: [ConnectionKind.androidUSB, .androidWiFi, .ricohGR, .cameraUSB], [false, true])
@MainActor func testedOrConnectingDeviceDisconnectNotifiesOnce(
  kind: ConnectionKind, connecting: Bool
) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(
    kind: kind, name: "device", params: ["serial": "local", "guid": "local"])
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  try await manager.save(connection, password: "")
  func update(_ present: Bool) {
    let ids: Set<String> = present ? ["local"] : []
    switch kind {
    case .androidUSB: manager.usbDevicesChanged(serials: ids)
    case .androidWiFi: manager.wirelessGUIDsChanged(ids)
    case .ricohGR: manager.ricohDevicesChanged(serials: ids)
    default: manager.cameraUSBDevicesChanged(serials: ids)
    }
  }
  update(true)
  var notices = 0
  manager.unexpectedDisconnect = { _ in notices += 1 }
  var completion: CheckedContinuation<SpaceInfo, Never>?
  var mounting: CheckedContinuation<Void, Never>?
  var task: Task<Void, Never>?
  if connecting {
    if kind.usesMount {
      f.smb.onMount = { _ in await withCheckedContinuation { mounting = $0 } }
    } else {
      manager.testRemote = { _ in await withCheckedContinuation { completion = $0 } }
    }
    task = Task { await manager.toggle(connection) }
    while completion == nil && mounting == nil { await Task.yield() }
  }
  update(false)
  update(false)
  #expect(notices == 1)
  #expect(manager.states[connection.id] == .disconnected)
  f.smb.mountFailure = RemoteError.notConnected
  mounting?.resume()
  completion?.resume(returning: SpaceInfo(total: 10, used: 1))
  await task?.value
  #expect(manager.states[connection.id] == .disconnected)
}

@Test(arguments: ["save", "mount", "remove"])
@MainActor func successfulOperationsRemoveStaleDetailedErrors(operation: String) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  f.smb.error = .authentication
  await manager.toggle(connection)
  #expect(manager.detailedErrors[connection.id] != nil)
  f.smb.error = nil
  switch operation {
  case "save": try await manager.save(connection, password: "test")
  case "mount": await manager.toggle(connection)
  default: try await manager.remove(connection)
  }
  #expect(manager.detailedErrors[connection.id] == nil)
}

@Test(arguments: ["remove", "edit", "disable"])
@MainActor func autoMountUsesCurrentConfigurationAfterAwait(operation: String) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var first = sample("first")
  first.autoMount = true
  var second = sample("second")
  second.autoMount = true
  try await manager.save(first, password: "first")
  try await manager.save(second, password: "second")
  var completion: CheckedContinuation<Void, Never>?
  f.smb.onMount = { connection in
    if connection.id == first.id { await withCheckedContinuation { completion = $0 } }
  }
  let task = Task { await manager.autoMount() }
  while completion == nil { await Task.yield() }
  switch operation {
  case "remove": try await manager.remove(second)
  case "edit":
    second.params["host"] = "192.0.2.30"
    try await manager.save(second, password: "second")
  default:
    second.autoMount = false
    try await manager.save(second, password: "second")
  }
  completion?.resume()
  await task.value
  let mountedSecond = f.smb.mountedConnections.filter { $0.id == second.id }
  if operation == "edit" {
    #expect(mountedSecond.count == 1)
    #expect(mountedSecond.first?.params["host"] == "192.0.2.30")
  } else {
    #expect(mountedSecond.isEmpty)
  }
}

@Test @MainActor func concurrentAutoMountRequestsDoNotMountTwice() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var connection = sample()
  connection.autoMount = true
  try await manager.save(connection, password: "test")
  var completion: CheckedContinuation<Void, Never>?
  f.smb.onMount = { _ in await withCheckedContinuation { completion = $0 } }
  let first = Task { await manager.autoMount() }
  while completion == nil { await Task.yield() }
  await manager.autoMount()
  completion?.resume()
  await first.value
  #expect(f.smb.mountedConnections.count == 1)
}

@Test @MainActor func lateCapacityRefreshCannotRestoreRemovedConnection() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  let mounted = try #require(f.smb.mounted(connection))
  var completion: CheckedContinuation<MountedShare?, Never>?
  f.smb.refreshVolume = { _ in await withCheckedContinuation { completion = $0 } }
  let refreshing = Task { await manager.refreshMountSpace() }
  while completion == nil { await Task.yield() }
  try await manager.remove(connection)
  completion?.resume(returning: MountedShare(url: mounted.url, availableBytes: 999))
  await refreshing.value
  #expect(manager.states[connection.id] == nil)
  #expect(manager.connections.isEmpty)
}

@Test @MainActor func capacityRefreshUpdatesCurrentMountWithoutDuplicateRequest() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  let mounted = try #require(f.smb.mounted(connection))
  var completion: CheckedContinuation<MountedShare?, Never>?
  var refreshes = 0
  f.smb.refreshVolume = { _ in
    refreshes += 1
    return await withCheckedContinuation { completion = $0 }
  }
  let first = Task { await manager.refreshMountSpace() }
  while completion == nil { await Task.yield() }
  await manager.refreshMountSpace()
  completion?.resume(returning: MountedShare(url: mounted.url, availableBytes: 999))
  await first.value
  #expect(refreshes == 1)
  #expect(
    manager.states[connection.id] == .mounted(MountedShare(url: mounted.url, availableBytes: 999)))
}

@Test(arguments: [false, true])
@MainActor func cancelledEjectionRestoresActualMountedState(explicit: Bool) async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  let mounted = try #require(f.smb.mounted(connection))
  f.smb.onUnmount = { _ in throw CancellationError() }
  var logged = 0
  manager.operationFailed = { _ in logged += 1 }
  if explicit { await manager.eject(connection) } else { await manager.toggle(connection) }
  #expect(manager.states[connection.id] == .mounted(mounted))
  #expect(manager.detailedErrors[connection.id] == nil)
  #expect(logged == 0)
}

@Test(arguments: [ConnectionState.connecting, .awaitingAuthorization])
@MainActor func cancellingIdlePendingStateDoesNotStartRemoteWork(state: ConnectionState) {
  let f = Fixture()
  defer { f.clean() }
  let connection = sample()
  let manager = ConnectionManager(
    location: f.location, secrets: f.secrets, smb: f.smb, initialStates: [connection.id: state])
  manager.cancelIdleOperation(connection)
  #expect(manager.states[connection.id] == .disconnected)
  #expect(f.smb.calls.isEmpty)
}

@Test(arguments: [ConnectionKind.androidUSB, .ricohGR, .cameraUSB])
@MainActor func devicePresenceUsesSavedIdentityInsteadOfDuplicateSerial(kind: ConnectionKind)
  async throws
{
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 10, used: 1) }
  let first = Connection(
    kind: kind, name: "first", params: ["serial": "duplicate", "deviceID": "usb:1"])
  let second = Connection(
    kind: kind, name: "second", params: ["serial": "duplicate", "deviceID": "usb:2"])
  try await manager.save(first, password: "")
  try await manager.save(second, password: "")
  func update(_ identities: Set<String>) {
    switch kind {
    case .androidUSB: manager.usbDevicesChanged(serials: identities)
    case .ricohGR: manager.ricohDevicesChanged(serials: identities)
    default: manager.cameraUSBDevicesChanged(serials: identities)
    }
  }
  update(["usb:1", "usb:2"])
  var notices: [UUID] = []
  manager.unexpectedDisconnect = { notices.append($0.id) }
  update(["usb:2"])
  #expect(notices == [first.id])
  #expect(manager.states[first.id] == .disconnected)
  #expect(manager.states[second.id] == .tested(SpaceInfo(total: 10, used: 1)))
}

@Test @MainActor func expectedSystemUnmountIsQuietBeforeDidUnmountNotification() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  try await manager.save(connection, password: "test")
  await manager.toggle(connection)
  let mounted = try #require(f.smb.mounted(connection))
  var notices = 0
  manager.unexpectedDisconnect = { _ in notices += 1 }
  manager.systemVolumeWillUnmount(at: mounted.url)
  f.smb.volumes.removeValue(forKey: connection.id)
  manager.refreshMounts()
  manager.systemVolumeUnmounted(at: mounted.url)
  #expect(notices == 0)
  #expect(manager.states[connection.id] == .disconnected)
}

@Test @MainActor func reorderToEndAndUndoPreservesPersistentOrder() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let a = sample("A")
  let b = sample("B")
  let c = sample("C")
  for connection in [a, b, c] { try await manager.save(connection, password: "test") }
  try manager.reorder(a.id, before: nil)
  #expect(manager.connections.map(\.id) == [b.id, c.id, a.id])
  #expect(f.manager().connections.map(\.order) == [0, 1, 2])
  try manager.reorder(a.id, before: b.id)
  #expect(f.manager().connections.map(\.id) == [a.id, b.id, c.id])
  try manager.reorder(a.id, before: UUID())
  #expect(manager.connections.map(\.id) == [a.id, b.id, c.id])
}

@Test @MainActor func presentationUndoChangesOnlyNameAndColor() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  var connection = sample("Original")
  connection.autoMount = true
  try await manager.save(connection, password: "retained")
  try manager.setPresentation(id: connection.id, name: "Renamed", color: "purple")
  let changed = try #require(f.manager().connections.first)
  #expect(changed.name == "Renamed")
  #expect(changed.color == "purple")
  #expect(changed.params == connection.params)
  #expect(changed.autoMount)
  #expect(try manager.savedPassword(changed) == "retained")
  try manager.setPresentation(id: connection.id, name: connection.name, color: connection.color)
  #expect(f.manager().connections.first?.name == "Original")
}

@Test @MainActor func usbTimeoutAdviceSurvivesSaveAndRetestErrorEntrypoints() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = Connection(kind: .androidUSB, name: "Phone", params: ["serial": "timeout-phone"])
  manager.usbDevicesChanged(serials: ["timeout-phone"])
  manager.testRemote = { _ in throw POSIXError(.ETIMEDOUT) }
  await #expect(throws: POSIXError.self) {
    try await manager.save(connection, password: "")
  }
  let expected = ConnectionState.failed(L("连接超时，请检查 USB 线缆并解锁手机后重试"))
  #expect(manager.states[connection.id] == expected)
  manager.testRemote = { _ in SpaceInfo(total: nil, used: nil) }
  try await manager.save(connection, password: "")
  f.smb.mountFailure = RemoteError.posix(ETIMEDOUT)
  await manager.toggle(connection)
  #expect(manager.states[connection.id] == expected)
}

// 设了自动挂载的设备：启动时已插着、拔掉后再插上都要通知外面去连接；没设的不管，一直插着不重复通知
@Test @MainActor func autoMountDeviceIsReportedWhenItComesBack() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  manager.testRemote = { _ in SpaceInfo(total: 100, used: 20) }
  let auto = Connection(kind: .androidUSB, name: "手机", autoMount: true, params: ["serial": "a", "deviceID": "a"])
  let manual = Connection(kind: .androidUSB, name: "备用机", params: ["serial": "b", "deviceID": "b"])
  try await manager.save(auto, password: "")
  try await manager.save(manual, password: "")
  var returned: [String] = []
  manager.deviceReturned = { returned.append($0.name) }
  manager.usbDevicesChanged(serials: ["a", "b"])
  #expect(returned == ["手机"])
  manager.usbDevicesChanged(serials: ["a", "b"])
  #expect(returned == ["手机"])
  manager.usbDevicesChanged(serials: ["b"])
  manager.usbDevicesChanged(serials: ["a", "b"])
  #expect(returned == ["手机", "手机"])
}

@Test @MainActor func mountFinishedPreservesTheErrorAndFinalState() async throws {
  let f = Fixture()
  defer { f.clean() }
  let connection = sample()
  try ConnectionRepository(location: f.location).save([connection])
  let manager = f.manager()
  let failure = NSError(domain: "MountFixture", code: 42)
  var results: [(UUID, Error?, ConnectionState?)] = []
  var notifications: [String] = []
  manager.mountFinished = { connection, error in
    results.append((connection.id, error, manager.states[connection.id]))
  }
  manager.mountFailed = { notifications.append($0) }
  f.smb.mountFailure = failure
  await manager.connectIfNeeded(connection)
  #expect(results.count == 1)
  #expect(results.first?.0 == connection.id)
  #expect((results.first?.1 as? NSError) === failure)
  if case .failed = results.first?.2 {} else { Issue.record("回调应看到失败状态") }
  #expect(notifications.count == 1)

  f.smb.mountFailure = nil
  await manager.connectIfNeeded(connection)
  #expect(results.count == 2)
  #expect(results.last?.1 == nil)
  if case .mounted = results.last?.2 {} else { Issue.record("回调应看到挂载状态") }
  await manager.connectIfNeeded(connection)
  #expect(results.count == 3)
  #expect(results.last?.1 == nil)
  #expect(f.smb.calls.filter { $0 == "mount" }.count == 2)
  #expect(notifications.count == 1)
}

@Test @MainActor func cancelledMountClearsTheRecoveryReasonWithoutFailureNotification() async throws {
  let f = Fixture()
  defer { f.clean() }
  let manager = f.manager()
  let connection = sample()
  var results = 0
  var notifications = 0
  manager.mountFinished = { _, error in
    #expect(error == nil)
    #expect(manager.states[connection.id] == .disconnected)
    results += 1
  }
  manager.mountFailed = { _ in notifications += 1 }
  f.smb.mountFailure = CancellationError()
  await manager.connectIfNeeded(connection)
  #expect(results == 1)
  #expect(notifications == 0)
}

@Test @MainActor func availableAutoMountDevicesRequireCurrentDiscoveryAndPreference() throws {
  let f = Fixture()
  defer { f.clean() }
  let usb = Connection(kind: .androidUSB, autoMount: true, params: ["deviceID": "usb"])
  let wifi = Connection(kind: .androidWiFi, autoMount: true, params: ["guid": "wifi"])
  let ricoh = Connection(kind: .ricohGR, autoMount: true, params: ["serial": "ricoh"])
  let camera = Connection(kind: .cameraUSB, autoMount: true, params: ["serial": "camera"])
  let manual = Connection(kind: .androidUSB, autoMount: false, params: ["deviceID": "usb"])
  let absent = Connection(kind: .androidUSB, autoMount: true, params: ["deviceID": "absent"])
  let cloud = Connection(kind: .quark, autoMount: true)
  let system = Connection(kind: .smb, autoMount: true)
  try ConnectionRepository(location: f.location).save([usb, wifi, ricoh, camera, manual, absent, cloud, system])
  let manager = f.manager()
  #expect(manager.availableAutoMountDevices.isEmpty)
  manager.usbDevicesChanged(serials: ["usb"])
  manager.wirelessGUIDsChanged(["wifi"])
  manager.ricohDevicesChanged(serials: ["ricoh"])
  manager.cameraUSBDevicesChanged(serials: ["camera"])
  #expect(Set(manager.availableAutoMountDevices.map(\.id)) == Set([usb.id, wifi.id, ricoh.id, camera.id]))
  manager.usbDevicesChanged(serials: [])
  #expect(Set(manager.availableAutoMountDevices.map(\.id)) == Set([wifi.id, ricoh.id, camera.id]))
}
