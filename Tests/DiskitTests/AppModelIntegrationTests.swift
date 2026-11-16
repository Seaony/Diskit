import AppKit
import CloudDrive
import Core
import CoreTestSupport
import Foundation
import Testing
import UserNotifications

@MainActor private final class ModelHarness {
  let location = LocalStorageLocation(
    home: FileManager.default.temporaryDirectory.appending(
      path: "DiskitModelTests-" + UUID().uuidString))
  let preferences = UserDefaults(suiteName: "DiskitModelTests." + UUID().uuidString)!
  let secrets = MemorySecretStore()
  var opened: [URL] = []
  var copied: [String] = []
  var alerts: [[String]] = []
  var status: UNAuthorizationStatus = .denied
  var requests = 0
  var notifications: [UNNotificationRequest] = []
  let notified = TestEvent()
  let presented = TestEvent()
  let didOpen = TestEvent()
  func model(info: [String: Any] = [:], provider: (any RemoteFileProvider)? = nil) -> AppModel {
    let system = AppSystemServices(
      open: { [self] in
        opened.append($0)
        didOpen.signal()
      }, copy: { [self] in copied.append($0) },
      alert: { [self] _, _, buttons, completion in
        alerts.append(buttons)
        completion(.alertThirdButtonReturn)
        presented.signal()
      },
      requestNotifications: { [self] in
        requests += 1
        status = .authorized
      },
      notificationStatus: { [self] in status },
      notify: { [self] in
        notifications.append($0)
        notified.signal()
      })
    let factory: ((Connection) async throws -> any RemoteFileProvider)?
    if let provider { factory = { _ in provider } } else { factory = nil }
    let dependencies = AppModelDependencies(
      location: location, secrets: secrets, preferences: preferences,
      smb: DemoMountService(delay: {}),
      httpTransport: EditorLoginHTTP { _ in throw RemoteError.unsupported },
      updates: UpdateController(isDemo: true), system: system, info: info,
      providerFactory: factory)
    let model = AppModel(options: RuntimeOptions(environment: [:]), dependencies: dependencies)
    model.configureConnections()
    return model
  }
}

@MainActor @Test func productionConfigurationsUseInjectedValuesAndPublicClientRules() throws {
  let harness = ModelHarness()
  var info: [String: Any] = [:]
  for prefix in ["ALIYUN", "BAIDU", "DRIVE115", "DRIVE123", "ONEDRIVE", "DROPBOX"] {
    info[prefix + "_CLIENT_ID"] = "client"
    info[prefix + "_CLIENT_SECRET"] = "secret"
    info[prefix + "_REDIRECT_URI"] = "diskit://callback"
  }
  info["GOOGLE_CLIENT_ID"] = "local.apps.googleusercontent.com"
  let model = harness.model(info: info)
  #expect(model.aliyunConfiguration.isConfigured)
  for kind: ConnectionKind in [
    .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox,
  ] {
    #expect(model.oauthIsConfigured(for: kind))
    let configuration = try #require(model.oauthConfiguration(for: kind))
    if [.oneDrive, .googleDrive, .dropbox].contains(kind) {
      #expect(configuration.clientSecret.isEmpty)
      #expect(configuration.usesPKCE)
    }
    let connection = Connection(kind: kind)
    let session = try model.oauthSession(for: connection)
    #expect(session === (try model.oauthSession(for: connection)))
    model.discardUnsavedSessions(for: connection)
    #expect(session !== (try model.oauthSession(for: connection)))
  }
  #expect(model.oauthConfiguration(for: .smb) == nil)
  #expect(!model.oauthIsConfigured(for: .smb))
  #expect(throws: OAuthDriveError.self) { try model.oauthSession(for: Connection(kind: .smb)) }
}

@MainActor @Test(arguments: [ConnectionKind.lanzou, .cameraUSB, .quark])
func productionRemoteTestAlwaysDisconnectsAndOnlyKnownReadOnlyTypesAllowUnknownSpace(
  kind: ConnectionKind
) async throws {
  let provider = EditorLoginProvider(capacityFailure: true)
  let model = ModelHarness().model(provider: provider)
  let test = try #require(model.connections.testRemote)
  if kind == .quark {
    await #expect(throws: RemoteError.self) { try await test(Connection(kind: kind)) }
  } else {
    let result = try await test(Connection(kind: kind))
    #expect(result.total == nil)
    #expect(result.available == nil)
  }
  #expect(await provider.connects == 1)
  #expect(await provider.disconnects == 1)
}

@MainActor @Test func productionRemoteProfileAndCapacityUseProviderAndReleaseIt() async throws {
  let provider = EditorLoginProvider()
  let model = ModelHarness().model(provider: provider)
  let connection = Connection(kind: .googleDrive)
  let profile = try await model.oauthProfile(for: connection)
  #expect(profile.userID == "fixture-user")
  let test = try #require(model.connections.testRemote)
  #expect(try await test(connection).available == 600)
  #expect(await provider.connects == 2)
  #expect(await provider.disconnects == 2)
}

@MainActor @Test func productionProviderFactoriesBuildWithIsolatedDependencies() async throws {
  let harness = ModelHarness()
  var info: [String: Any] = [:]
  for prefix in ["BAIDU", "DRIVE115", "DRIVE123", "ONEDRIVE", "DROPBOX"] {
    info[prefix + "_CLIENT_ID"] = "client"
    info[prefix + "_CLIENT_SECRET"] = "secret"
    info[prefix + "_REDIRECT_URI"] = "diskit://callback"
  }
  info["GOOGLE_CLIENT_ID"] = "local.apps.googleusercontent.com"
  let model = harness.model(info: info)
  for kind: ConnectionKind in [
    .aliyunDrive, .quark, .ucDrive, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
    .dropbox, .pikPak, .tianyiDrive, .mobileCloud, .thunderDrive, .s3, .cloudflareR2, .aliyunOSS,
    .tencentCOS, .qiniuKodo, .minIO, .backblazeB2,
  ] {
    let connection = Connection(
      kind: kind,
      params: ["endpoint": "https://fixture.invalid", "bucket": "bucket", "phone": "13800000000"])
    try harness.secrets.write(Data("local-secret".utf8), for: connection.passwordKey)
    _ = try await model.remoteProvider(for: connection)
  }
  await #expect(throws: ConnectionError.self) {
    try await model.remoteProvider(for: Connection(kind: .smb))
  }
  let share = Connection(
    kind: .lanzou, params: ["authMode": "share", "shareURL": "https://fixture.lanzou.com/folder"])
  _ = try await model.remoteProvider(for: share)
}

@MainActor @Test func productionNotificationsUseInjectedPermissionAndDesktopServices() async throws
{
  let harness = ModelHarness()
  let model = harness.model()
  await model.refreshNotificationAuthorization()
  #expect(model.notificationAuthorization == .denied)
  await model.requestNotificationAuthorization()
  #expect(harness.requests == 1)
  #expect(model.notificationAuthorization == .authorized)
  model.openNotificationSettings()
  #expect(harness.opened.first?.scheme == "x-apple.systempreferences")
  model.reportMountFailure("fixture failure")
  try await harness.notified.wait()
  #expect(harness.notifications.count == 1)
  #expect(harness.notifications[0].content.body == "fixture failure")
  harness.preferences.set(false, forKey: "notifications.mountFailure")
  model.reportMountFailure("disabled")
  #expect(harness.notifications.count == 1)
  let url = URL(fileURLWithPath: "/fixture/mount")
  model.connections.openInFinder?(url)
  #expect(harness.opened.last == url)
}

@MainActor @Test func firstNotificationAsksForPermissionOnceAndSendsAfterAllowed() async throws {
  let harness = ModelHarness()
  harness.status = .notDetermined
  let model = harness.model()
  model.reportMountFailure("first")
  try await harness.notified.wait()
  #expect(harness.requests == 1)
  #expect(model.notificationAuthorization == .authorized)
  #expect(harness.notifications.map(\.content.body) == ["first"])
  model.reportMountFailure("second")
  for _ in 0..<100 where harness.notifications.count < 2 { await Task.yield() }
  #expect(harness.requests == 1)
  #expect(harness.notifications.count == 2)
}

@MainActor @Test func deniedNotificationsAreNotRequestedAgainOrSent() async throws {
  let harness = ModelHarness()
  let model = harness.model()
  model.reportMountFailure("denied")
  for _ in 0..<100 { await Task.yield() }
  #expect(harness.requests == 0)
  #expect(harness.notifications.isEmpty)
}

@MainActor @Test func productionCacheMaintenanceOnlyTouchesInjectedDirectory() async throws {
  let harness = ModelHarness()
  let model = harness.model()
  let directory = harness.location.cacheDirectory
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data(repeating: 1, count: 128).write(to: directory.appending(path: "fixture"))
  #expect(try await model.cacheSize() >= 128)
  harness.preferences.set(-1, forKey: "cacheLimitGB")
  await model.enforceCacheLimit()
  #expect(FileManager.default.fileExists(atPath: directory.appending(path: "fixture").path))
  await model.clearCache()
  #expect(try await model.cacheSize() == 0)
  #expect(harness.alerts.isEmpty)
  try? FileManager.default.removeItem(
    at: harness.location.dataDirectory.deletingLastPathComponent())
}

@MainActor @Test func productionExpiredLoginUpdatesOnlySavedConnectionOnce() async throws {
  let harness = ModelHarness()
  harness.status = .authorized
  let connection = Connection(kind: .googleDrive, name: "saved")
  try ConnectionRepository(location: harness.location).save([connection])
  let model = harness.model()
  model.connections.loginExpired?(Connection(kind: .googleDrive))
  #expect(harness.notifications.isEmpty)
  model.connections.loginExpired?(connection)
  try await harness.notified.wait()
  #expect(model.connections.states[connection.id] == .needsLogin)
  #expect(harness.notifications.count == 1)
  model.connections.loginExpired?(connection)
  #expect(harness.notifications.count == 1)
}

@MainActor @Test func productionDiscardKeepsSavedSessionsAndDropsDraftSessions() throws {
  let harness = ModelHarness()
  let saved = Connection(kind: .pikPak)
  try ConnectionRepository(location: harness.location).save([saved])
  let model = harness.model()
  let original = model.pikPakSession(for: saved)
  model.discardUnsavedSessions(for: saved)
  #expect(original === model.pikPakSession(for: saved))
  let draft = Connection(kind: .pikPak)
  let transient = model.pikPakSession(for: draft)
  model.discardUnsavedSessions(for: draft)
  #expect(transient !== model.pikPakSession(for: draft))
}

private struct FailingModelProvider: RemoteFileProvider, OAuthProfileProviding {
  enum Stage: Sendable { case connect, profile }
  let stage: Stage
  let base = EditorLoginProvider()
  var capabilities: ProviderCapabilities { base.capabilities }
  func connect() async throws {
    try await base.connect()
    if stage == .connect { throw RemoteError.unauthorized }
  }
  func disconnect() async { await base.disconnect() }
  func profile() async throws -> OAuthProfile { throw RemoteError.unauthorized }
  func spaceInfo() async throws -> SpaceInfo { try await base.spaceInfo() }
  func list(_ path: RemotePath) async throws -> [RemoteItem] { throw RemoteError.unsupported }
  func stat(_ path: RemotePath) async throws -> RemoteItem { throw RemoteError.unsupported }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > { throw RemoteError.unsupported }
  func write(_ path: RemotePath, from localFile: URL) async throws { throw RemoteError.unsupported }
  func makeDirectory(_ path: RemotePath) async throws { throw RemoteError.unsupported }
  func remove(_ path: RemotePath, recursive: Bool) async throws { throw RemoteError.unsupported }
  func move(_ from: RemotePath, to: RemotePath) async throws { throw RemoteError.unsupported }
}

@MainActor @Test func productionProfileAndConnectionFailureAlwaysReleaseProvider() async throws {
  for stage in [FailingModelProvider.Stage.connect, .profile] {
    let provider = FailingModelProvider(stage: stage)
    let model = ModelHarness().model(provider: provider)
    await #expect(throws: RemoteError.self) {
      try await model.oauthProfile(for: Connection(kind: .googleDrive))
    }
    #expect(await provider.base.disconnects == 1)
    if stage == .connect {
      let test = try #require(model.connections.testRemote)
      await #expect(throws: RemoteError.self) { try await test(Connection(kind: .googleDrive)) }
      #expect(await provider.base.disconnects == 2)
    }
  }
}

@MainActor @Test func productionLogPresentationUsesInjectedWorkspaceAndReportsDirectoryFailure()
  async throws
{
  let success = ModelHarness()
  let model = success.model()
  model.showLogs()
  try await success.didOpen.wait()
  #expect(success.opened.last == success.location.dataDirectory.appending(path: "Logs"))
  let failure = ModelHarness()
  try FileManager.default.createDirectory(
    at: failure.location.dataDirectory, withIntermediateDirectories: true)
  try Data("blocked".utf8).write(to: failure.location.dataDirectory.appending(path: "Logs"))
  let broken = failure.model()
  broken.showLogs()
  try await failure.presented.wait()
  #expect(failure.alerts.first?.count == 3)
  #expect(failure.copied.count == 1)
  #expect(failure.opened.isEmpty)
}

@MainActor @Test func productionCapabilitiesComeFromConnectedProviderAndExpireAfterAddressEdit()
  async throws
{
  let provider = EditorLoginProvider()
  let model = ModelHarness().model(provider: provider)
  var connection = Connection(kind: .quark)
  #expect(model.providerCapabilities(for: connection) == nil)
  let test = try #require(model.connections.testRemote)
  _ = try await test(connection)
  let capabilities = try #require(model.providerCapabilities(for: connection))
  #expect(ProviderAccess.isReadOnly(capabilities))
  connection.params["account"] = "different"
  #expect(model.providerCapabilities(for: connection) == nil)
  #expect(!ProviderAccess.isReadOnly(nil))
  #expect(
    !ProviderAccess.isReadOnly(
      ProviderCapabilities(
        canWrite: false, canRename: false, canMove: false, canDelete: true, supportsRangeRead: true)
    ))
}

@MainActor @Test func demoCapabilitiesNeverConstructRealProviders() {
  let model = AppModel(
    options: RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": "types"]))
  #expect(ProviderAccess.isReadOnly(model.providerCapabilities(for: Connection(kind: .lanzou))))
  #expect(!ProviderAccess.isReadOnly(model.providerCapabilities(for: Connection(kind: .smb))))
}

// 设备询问：换个 USB 口仍认得出同一台；拒绝后记在偏好里，重新启动也不再问
@MainActor @Test func declinedDevicePromptIsRemembered() throws {
  let harness = ModelHarness()
  let model = harness.model()
  let phone = DiscoveredItem(
    id: "usb:usb:1", kind: .androidUSB, title: "Xiaomi 17", subtitle: "",
    connection: Connection(kind: .androidUSB, name: "Xiaomi 17", params: ["serial": "564d", "deviceID": "564d"]),
    pairingSelection: nil)
  let otherPort = DiscoveredItem(
    id: "usb:usb:2", kind: .androidUSB, title: "Xiaomi 17", subtitle: "",
    connection: phone.connection, pairingSelection: nil)
  #expect(DevicePrompt.key(phone) == DevicePrompt.key(otherPort))
  let noSerial = DiscoveredItem(
    id: "camera-usb:9", kind: .cameraUSB, title: "Camera", subtitle: "",
    connection: Connection(kind: .cameraUSB, name: "Camera", params: ["deviceID": "9", "serial": ""]),
    pairingSelection: nil)
  #expect(DevicePrompt.key(noSerial) == "camera-usb:9")
  model.declineDevicePrompt(phone)
  #expect(model.declinedDevices.contains(DevicePrompt.key(phone)))
  #expect(harness.model().declinedDevices.contains(DevicePrompt.key(phone)))
}
