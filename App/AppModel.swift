import ADB
import AliyunDrive
import AppKit
import CameraUSB
import ChinaWebDrive
import CloudDrive
import Core
import Foundation
import LanzouDrive
import Network
import OSLog
import Observation
import PikPakDrive
import Quark
import RicohGR
import S3Drive
import TianyiDrive
import UserNotifications

@MainActor @Observable final class AppModel {
  let connections: ConnectionManager
  let operations = AppOperations()
  let undoManager = UndoManager()
  let options: RuntimeOptions
  let updates: UpdateController
  let preferences: UserDefaults
  let secrets: any SecretStore
  let fileSystem: FileSystemMountService?
  var fileSystemState: FileSystemExtensionState = .checking
  private let dependencies: AppModelDependencies?
  let system: AppSystemServices
  private let info: [String: Any]
  private let location: any StorageLocation
  private let maintenance = CacheMaintenance()
  private let fileSystemCache: FileSystemCacheMaintenance
  private let sessionCache = RemoteSessionCache()
  private var providerAccess: [UUID: (connection: Connection, capabilities: ProviderCapabilities)] =
    [:]
  var demoSetupError: String?
  private(set) var quitFailure: QuitFailure?
  private var quitWithoutEjecting = false
  var demoEditorStateOverride: DemoEditorState?
  var demoEditorRevision = 0
  var demoAppearanceOverride: String?
  // 第一次发现设备时问要不要添加：拒绝过的设备（存在偏好里）、本次已发过通知的设备、正在连接的设备和各设备连接失败的原因
  var declinedDevices: Set<String> = []
  var notifiedDevices: Set<String> = []
  var mountingPromptDevice: String?
  var devicePromptErrors: [String: String] = [:]

  init(options: RuntimeOptions = .current, dependencies: AppModelDependencies? = nil) {
    self.options = options
    self.dependencies = dependencies
    system = dependencies?.system ?? .live
    info = dependencies?.info ?? Bundle.main.infoDictionary ?? [:]
    updates = dependencies?.updates ?? UpdateController(isDemo: options.isDemo)
    if let dependencies {
      fileSystem = dependencies.fileSystem
      location = dependencies.location
      secrets = dependencies.secrets
      preferences = dependencies.preferences
      connections = ConnectionManager(
        location: dependencies.location, secrets: dependencies.secrets, smb: dependencies.smb)
    } else if options.isDemo {
      fileSystem = nil
      fileSystemState = .enabled
      let identifier = UUID().uuidString
      let home = FileManager.default.temporaryDirectory.appending(path: "DiskitDemo-" + identifier)
      let location = LocalStorageLocation(home: home)
      self.location = location
      let secrets = MemorySecretStore()
      self.secrets = secrets
      preferences = UserDefaults(suiteName: "com.seaony.Diskit.demo." + identifier)!
      let fixture = DemoFixtures(scenario: options.scenario)
      do { try ConnectionRepository(location: location).save(fixture.connections) } catch {
        demoSetupError = HumanError.detail(error)
      }
      connections = ConnectionManager(
        location: location, secrets: secrets,
        smb: DemoMountService(states: fixture.states), initialStates: fixture.states)
    } else {
      let storage = RuntimeStorage.current
      let fileSystem = FileSystemMountService(location: storage.location)
      self.fileSystem = fileSystem
      location = storage.location
      secrets = storage.secrets
      preferences = .standard
      connections = ConnectionManager(
        location: storage.location, secrets: storage.secrets,
        smb: RoutingMountService(
          system: SystemSMBService(location: storage.location), fileSystem: fileSystem))
    }
    fileSystemCache = FileSystemCacheMaintenance(
      root: dependencies != nil || options.isDemo
        ? location.dataDirectory.appending(path: "FileSystemCache")
        : FileSystemCacheMaintenance.defaultRoot)
    declinedDevices = Set(preferences.stringArray(forKey: DevicePrompt.declinedKey) ?? [])
    if let notification = options.demoNotification {
      notificationAuthorization = notification.authorization
    }
    if options.demoLoadError { demoSetupError = L("文件无法读取，请检查访问权限") }
    connections.removed = { [weak self] id in
      self?.sessionCache.remove(id)
      self?.providerAccess.removeValue(forKey: id)
    }
  }

  private var showsDemoDiscovery: Bool { options.isDemo && options.scenario != "empty" }
  var usbDevices: [ADBDevice] {
    options.isDemo
      ? (showsDemoDiscovery ? [ADBDevice(serial: "demo-usb", name: "Pixel 8", registryID: 0)] : [])
      : usbDiscovery.devices
  }
  var wirelessDevices: [WirelessDevice] {
    options.isDemo
      ? (showsDemoDiscovery
        ? [
          WirelessDevice(
            name: "adb-discovered-DEF456", type: .pairing, host: "demo.invalid", port: 12345)
        ] : []) : wirelessDiscovery.devices
  }
  var ricohDevices: [RicohDevice] {
    options.isDemo
      ? (showsDemoDiscovery ? [RicohDevice(id: "demo-gr", serial: "demo-gr", name: "GR IV")] : [])
      : ricohDiscovery.devices
  }
  var cameraUSBDevices: [CameraUSBDevice] {
    options.isDemo
      ? (showsDemoDiscovery
        ? [
          CameraUSBDevice(
            id: "demo-camera", serial: "demo-camera", name: "USB Camera", vendorID: 0, productID: 0)
        ] : []) : cameraUSBDiscovery.devices
  }
  var smbDevices: [DiscoveredSMB] {
    options.isDemo
      ? (showsDemoDiscovery
        ? [DiscoveredSMB(id: "demo-smb", name: "Demo NAS", host: "discovered.invalid")] : [])
      : discovery.devices
  }
  let discovery = SMBDiscovery()
  let usbDiscovery = USBDiscovery()
  let wirelessDiscovery = WirelessDiscovery()
  let ricohDiscovery = RicohDiscovery()
  let cameraUSBDiscovery = CameraUSBDiscovery()
  var pairingSelection: String?
  var forceLogin = false
  var editing: Connection?
  var notificationAuthorization: UNAuthorizationStatus = .notDetermined
  private let networkMonitor = NWPathMonitor()
  private var lastNetworkPath: NWPath?
  @ObservationIgnored private lazy var recovery = ConnectionRecovery(
    operations: operations,
    refresh: { [weak self] in self?.connections.refreshMounts() },
    recover: { [weak self] in
      guard let self else { return }
      discovery.restart()
      await connections.refreshMountSpace()
      await connections.autoMount()
    })
  private var started = false
  private var observers: [NSObjectProtocol] = []
  private var observesFileSystemLogin = false
  private let logger = Logger(subsystem: "com.seaony.Diskit", category: "connections")
  func start() {
    guard !started else { return }
    started = true
    if options.isDemo {
      connections.testRemote = { _ in
        try await Task.sleep(for: .seconds(2))
        return SpaceInfo(total: 256_000_000_000, used: 136_000_000_000)
      }
      return
    }
    configureConnections()
    connections.deviceReturned = { [weak self] connection in
      guard let self else { return }
      self.operations.start(connectionID: connection.id) {
        await self.connections.connectIfNeeded(connection)
      }
    }
    connections.deviceDisappeared = { [weak self] connection in
      guard let self, !operations.isStopping else { return }
      Task { @MainActor in
        await operations.cancelAndWait(connectionID: connection.id)
        do { try await fileSystem?.settlePendingMounts() } catch {
          logger.error("设备消失后的挂载未结束 id=\(connection.id.uuidString, privacy: .public)")
        }
        await connections.eject(connection)
      }
    }
    usbDiscovery.changed = { [weak self] devices in
      self?.connections.usbDevicesChanged(serials: ADBUSB.availableIdentifiers(in: devices))
      self?.refreshWirelessAvailability()
      self?.refreshDevicePrompts()
    }
    wirelessDiscovery.changed = { [weak self] _ in self?.refreshWirelessAvailability() }
    wirelessDiscovery.start()
    usbDiscovery.start()
    ricohDiscovery.changed = { [weak self] devices in
      self?.connections.ricohDevicesChanged(
        serials: Self.deviceIdentifiers(devices.map { ($0.id, $0.serial) }))
      self?.refreshDevicePrompts()
    }
    ricohDiscovery.start()
    cameraUSBDiscovery.changed = { [weak self] devices in
      self?.connections.cameraUSBDevicesChanged(
        serials: Self.deviceIdentifiers(devices.map { ($0.id, $0.serial) }))
      self?.refreshDevicePrompts()
    }
    cameraUSBDiscovery.start()
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didMountNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.operations.isStopping else { return }
          self.connections.refreshMounts()
        }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        MainActor.assumeIsolated {
          guard let self, !self.operations.isStopping, let url else { return }
          self.connections.systemVolumeWillUnmount(at: url)
        }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        MainActor.assumeIsolated {
          guard let self, !self.operations.isStopping else { return }
          if let url {
            self.connections.systemVolumeUnmounted(at: url)
          } else {
            self.connections.refreshMounts()
          }
        }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.discovery.stop()
          self?.recovery.willSleep()
        }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.recovery.didWake() }
      })
    for name in [
      AliyunSession.loginInvalidatedNotification, QuarkSession.loginInvalidatedNotification,
      OAuthSession.invalidationNotification, PikPakSession.loginInvalidatedNotification,
      TianyiSession.loginInvalidatedNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] notification in
          guard let key = notification.userInfo?["secretKey"] as? String,
            let id = UUID(uuidString: String(key.prefix(36)))
          else { return }
          Task { @MainActor in self?.loginExpired(id) }
        })
    }
    observeFileSystemLoginEvents()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.refreshFileSystemState() }
      })
    networkMonitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in self?.networkPathChanged(path) }
    }
    networkMonitor.start(queue: DispatchQueue(label: "com.seaony.Diskit.networkRecovery"))
    recovery.start()
    Task { await refreshNotificationAuthorization() }
    Task { await enforceCacheLimit() }
    Task { await refreshFileSystemState() }
  }
  func observeFileSystemLoginEvents() {
    guard !observesFileSystemLogin else { return }
    observesFileSystemLogin = true
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: FileSystemLoginEvent.notification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let text = notification.object as? String, let id = UUID(uuidString: text) else {
          return
        }
        Task { @MainActor in
          guard let self,
            let connection = self.connections.connections.first(where: { $0.id == id }),
            connection.kind.fileSystemScheme != nil, FileSystemLoginEvent.supports(kind: connection.kind)
          else { return }
          self.loginExpired(id)
        }
      })
  }

  private func networkPathChanged(_ path: NWPath) {
    guard !operations.isStopping, lastNetworkPath != path else { return }
    lastNetworkPath = path
    if path.status != .satisfied { discovery.stop() }
    recovery.networkChanged(available: path.status == .satisfied)
  }

  func prepareToQuit() {
    operations.cancelAll()
  }

  func cancelQuitAfterFailure() {
    guard quitFailure != nil else { return }
    quitFailure = nil
    quitWithoutEjecting = false
  }

  func confirmQuitAfterFailure() -> Bool {
    guard quitFailure != nil else { return false }
    quitFailure = nil
    quitWithoutEjecting = true
    return true
  }

  @discardableResult func finishQuitting() async -> Bool {
    await operations.finishCancellation()
    let skipEjection = quitWithoutEjecting
    quitWithoutEjecting = false
    quitFailure = nil
    var failures: [QuitFailure.Location] = []
    do {
      if !skipEjection {
        try await fileSystem?.unmountAll { [self] url, error in
          let connection = connections.connections.first {
            fileSystem?.mounted($0)?.url.standardizedFileURL == url.standardizedFileURL
          }
          failures.append(QuitFailure.Location(
            id: connection?.id.uuidString ?? url.absoluteString,
            name: connection?.name ?? url.lastPathComponent,
            reason: QuitFailure.reason(for: error)))
        }
        try await connections.ejectOwnedVolumes { [self] connection, error in
          logger.error("退出时推出失败 id=\(connection.id.uuidString, privacy: .public) \(ErrorDiagnostics.summary(error), privacy: .public)")
          failures.append(QuitFailure.Location(
            id: connection.id.uuidString, name: connection.name,
            reason: QuitFailure.reason(for: error)))
        }
      }
      networkMonitor.cancel()
      if !options.isDemo { discovery.stop() }
      recovery.stop()
      return true
    } catch {
      operations.resume()
      if started && !options.isDemo { recovery.start() }
      logger.error("退出前推出失败：\(ErrorDiagnostics.summary(error), privacy: .public)")
      quitFailure = QuitFailure(locations: failures, reason: QuitFailure.reason(for: error))
      return false
    }
  }

  func refreshFileSystemState() async {
    guard let fileSystem else { return }
    fileSystemState = await fileSystem.extensionStatus()
  }

  func openFileSystemSettings() {
    guard !options.isDemo else { return }
    guard fileSystem?.openSettings() == true else {
      presentOperationAlert(title: L("无法打开系统设置"), message: L("请打开系统设置，在登录项与扩展中启用 Diskit。"))
      return
    }
  }

  func toggleConnection(_ connection: Connection) async {
    if let fileSystem, connection.kind.fileSystemScheme != nil,
      fileSystem.mounted(connection) == nil
    {
      await refreshFileSystemState()
      if fileSystemState == .disabled {
        system.alert(
          L("启用文件系统扩展"), L("在系统设置中启用 Diskit 后即可挂载位置。"),
          [L("打开系统设置"), L("取消")]
        ) { [weak self] response in
          if response == .alertFirstButtonReturn { self?.openFileSystemSettings() }
        }
        return
      }
    }
    await connections.toggle(connection)
  }

  func configureConnections() {
    connections.openInFinder = { [system] in system.open($0) }
    connections.operationFailed = { [weak self] message in
      self?.logger.error("\(message, privacy: .public)")
      self?.writeError(message)
    }
    connections.mountFailed = { [weak self] message in self?.reportMountFailure(message) }
    connections.loginExpired = { [weak self] connection in self?.loginExpired(connection.id) }
    connections.unexpectedDisconnect = { [weak self] connection in
      self?.writeError(L("位置意外断开"))
      self?.sendNotification(
        .disconnect,
        title: L("位置意外断开"),
        body: LF("“%@”的连接已断开。", connection.name))
    }
    connections.testRemote = { [weak self] connection in
      guard let self else { throw ConnectionError.notImplemented }
      let provider = try await self.remoteProvider(for: connection)
      do {
        try await provider.connect()
        self.providerAccess[connection.id] = (connection, provider.capabilities)
        let space: SpaceInfo
        do {
          space = try await provider.spaceInfo()
        } catch RemoteError.unsupported
          where connection.kind == .lanzou
          || connection.kind == .cameraUSB
        {
          space = SpaceInfo(total: nil, used: nil)
        }
        await provider.disconnect()
        self.refreshWirelessAvailability(additional: connection)
        return space
      } catch {
        await provider.disconnect()
        throw error
      }
    }
  }

  func providerCapabilities(for connection: Connection) -> ProviderCapabilities? {
    if options.isDemo {
      guard connection.kind == .lanzou || connection.kind == .cameraUSB else { return nil }
      return ProviderCapabilities(
        canWrite: false, canRename: false, canMove: false, canDelete: false,
        supportsRangeRead: true)
    }
    guard let entry = providerAccess[connection.id], entry.connection.kind == connection.kind,
      entry.connection.params == connection.params
    else { return nil }
    return entry.capabilities
  }

  func makeHTTPTransport(cookieDomain: String? = nil) -> any HTTPTransport {
    dependencies?.httpTransport ?? URLSessionHTTPTransport(cookieDomain: cookieDomain)
  }

  var aliyunConfiguration: AliyunConfiguration {
    return AliyunConfiguration(
      clientID: info["ALIYUN_CLIENT_ID"] as? String ?? "",
      clientSecret: info["ALIYUN_CLIENT_SECRET"] as? String ?? "",
      redirectURI: info["ALIYUN_REDIRECT_URI"] as? String ?? "")
  }
  func aliyunSession(for connection: Connection) -> AliyunSession {
    sessionCache.value(for: connection, configuration: aliyunConfiguration) {
      AliyunSession(
        secretKey: "\(connection.id.uuidString).oauth", secrets: secrets,
        configuration: aliyunConfiguration, transport: makeHTTPTransport())
    }
  }
  func discardUnsavedSessions(for connection: Connection) {
    guard !connections.connections.contains(where: { $0.id == connection.id }) else { return }
    sessionCache.remove(connection.id)
    providerAccess.removeValue(forKey: connection.id)
  }
  func pikPakSession(for connection: Connection) -> PikPakSession {
    sessionCache.value(for: connection, configuration: "pikPak") {
      PikPakSession(
        secretKey: "\(connection.id.uuidString).oauth.pikPak", secrets: secrets,
        transport: makeHTTPTransport())
    }
  }
  func quarkSession(for connection: Connection) -> QuarkSession {
    let configuration = connection.kind == .ucDrive ? QuarkCloudConfiguration.uc : .quark
    return sessionCache.value(for: connection, configuration: configuration) {
      QuarkSession(
        secretKey: "\(connection.id.uuidString).cookie", secrets: secrets,
        configuration: configuration,
        transport: makeHTTPTransport(cookieDomain: configuration.cookieDomain))
    }
  }
  func tianyiSession(for connection: Connection, personal: Bool = false) -> TianyiSession {
    let familyID = connection.params["familyID"] ?? ""
    let configuration =
      !personal && connection.params["scope"] == "family"
      ? TianyiConfiguration.family(familyID: familyID) : TianyiConfiguration.personal
    return sessionCache.value(
      for: connection, configuration: configuration,
      slot: configuration == .personal ? "personal" : "family"
    ) {
      TianyiSession(
        secretKey: "\(connection.id.uuidString).oauth.tianyiDrive", secrets: secrets,
        configuration: configuration,
        transport: makeHTTPTransport(cookieDomain: configuration.cookieDomain))
    }
  }
  func oauthConfiguration(for kind: ConnectionKind) -> OAuthConfiguration? {
    func value(_ key: String) -> String { info[key] as? String ?? "" }
    switch kind {
    case .baiduDrive:
      return OAuthConfiguration(
        clientID: value("BAIDU_CLIENT_ID"),
        clientSecret: value("BAIDU_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!,
        tokenURL: URL(string: "https://openapi.baidu.com/oauth/2.0/token")!,
        redirectURI: value("BAIDU_REDIRECT_URI"),
        scopes: ["basic", "netdisk"], scopeSeparator: ",",
        tokenRequestMethod: "GET", tokenRequestPlacement: .query)
    case .drive115:
      return OAuthConfiguration(
        clientID: value("DRIVE115_CLIENT_ID"),
        clientSecret: value("DRIVE115_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://passportapi.115.com/open/authorize")!,
        tokenURL: URL(string: "https://passportapi.115.com/open/authCodeToToken")!,
        refreshTokenURL: URL(string: "https://passportapi.115.com/open/refreshToken")!,
        redirectURI: value("DRIVE115_REDIRECT_URI"), scopes: [],
        tokenResponseDataKey: "data", refreshGrantIncludesClientCredentials: false)
    case .drive123:
      return OAuthConfiguration(
        clientID: value("DRIVE123_CLIENT_ID"),
        clientSecret: value("DRIVE123_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://yun.123pan.com/auth")!,
        tokenURL: URL(string: "https://open-api.123pan.com/api/v1/oauth2/access_token")!,
        redirectURI: value("DRIVE123_REDIRECT_URI"),
        scopes: ["user:base", "file:all:read", "file:all:write"], scopeSeparator: ",")
    case .oneDrive:
      return OAuthConfiguration(
        clientID: value("ONEDRIVE_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(
          string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        redirectURI: value("ONEDRIVE_REDIRECT_URI"),
        scopes: ["offline_access", "User.Read", "Files.ReadWrite"], usesPKCE: true)
    case .googleDrive:
      return OAuthConfiguration(
        clientID: value("GOOGLE_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        redirectURI: GoogleDesktopOAuth.redirectURI(clientID: value("GOOGLE_CLIENT_ID")),
        scopes: [
          "openid", "email", "profile", "https://www.googleapis.com/auth/drive",
        ],
        additionalAuthorizationItems: ["access_type": "offline", "prompt": "consent"],
        usesPKCE: true)
    case .dropbox:
      return OAuthConfiguration(
        clientID: value("DROPBOX_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        redirectURI: value("DROPBOX_REDIRECT_URI"),
        scopes: [
          "account_info.read", "files.content.read", "files.content.write",
          "files.metadata.read", "files.metadata.write",
        ],
        additionalAuthorizationItems: ["token_access_type": "offline"], usesPKCE: true)
    default:
      return nil
    }
  }
  func oauthIsConfigured(for kind: ConnectionKind) -> Bool {
    guard let configuration = oauthConfiguration(for: kind), configuration.isConfigured else {
      return false
    }
    return true
  }
  func oauthSession(for connection: Connection) throws -> OAuthSession {
    guard oauthIsConfigured(for: connection.kind),
      let configuration = oauthConfiguration(for: connection.kind)
    else { throw OAuthDriveError.configuration }
    return sessionCache.value(for: connection, configuration: configuration) {
      OAuthSession(
        configuration: configuration,
        secretKey: "\(connection.id.uuidString).oauth.\(connection.kind.rawValue)",
        secrets: secrets,
        transport: makeHTTPTransport()
      )
    }
  }
  func remoteProvider(for connection: Connection) async throws -> any RemoteFileProvider {
    if let factory = dependencies?.providerFactory { return try await factory(connection) }
    guard !options.isDemo else { throw ConnectionError.notImplemented }
    switch connection.kind {
    case .androidUSB, .androidWiFi:
      return try await ADBProviderFactory.make(for: connection)
    case .ricohGR:
      return try await RicohProvider.make(
        identifier: connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    case .cameraUSB:
      return try await CameraUSBProvider.make(
        identifier: connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    case .aliyunDrive:
      return AliyunProvider(session: aliyunSession(for: connection))
    case .quark, .ucDrive:
      return QuarkProvider(session: quarkSession(for: connection))
    case .baiduDrive:
      let root = info["BAIDU_ROOT_PATH"] as? String ?? "apps/Diskit"
      let appID = info["BAIDU_APP_ID"] as? String ?? ""
      return BaiduDriveProvider(
        configuration: BaiduDriveConfiguration(rootPath: root, appID: appID),
        session: try oauthSession(for: connection))
    case .drive115:
      return Drive115Provider(session: try oauthSession(for: connection))
    case .drive123:
      return Drive123Provider(session: try oauthSession(for: connection))
    case .oneDrive:
      return OneDriveProvider(session: try oauthSession(for: connection))
    case .googleDrive:
      return GoogleDriveProvider(session: try oauthSession(for: connection))
    case .dropbox:
      return DropboxProvider(session: try oauthSession(for: connection))
    case .pikPak:
      return PikPakProvider(session: pikPakSession(for: connection))
    case .tianyiDrive:
      return TianyiProvider(session: tianyiSession(for: connection))
    case .lanzou:
      return LanzouProvider(session: try lanzouSession(for: connection))
    case .mobileCloud:
      return MobileCloudProvider(session: try mobileCloudSession(for: connection))
    case .thunderDrive:
      return XunleiProvider(session: try xunleiSession(for: connection))
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      guard let endpoint = URL(string: connection.params["endpoint"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      let secret =
        try secrets.read(connection.passwordKey).map {
          String(decoding: $0, as: UTF8.self)
        } ?? ""
      let configuration = S3Configuration(
        endpoint: endpoint, region: connection.params["region"] ?? "us-east-1",
        bucket: connection.params["bucket"] ?? "",
        accessKey: connection.params["accessKey"] ?? "", secretKey: secret,
        pathStyle: connection.params["pathStyle"] != "false")
      return S3Provider(
        configuration: configuration,
        transport: dependencies?.httpTransport
          ?? s3Transport(for: connection, configuration: configuration))
    default:
      throw ConnectionError.notImplemented
    }
  }
  func lanzouSession(for connection: Connection) throws -> LanzouSession {
    let secret = try savedRemoteSecret(for: connection)
    let authentication: LanzouAuthentication
    if connection.params["authMode"] == "share" {
      guard let url = URL(string: connection.params["shareURL"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      authentication = .share(url: url, password: secret.isEmpty ? nil : secret)
    } else {
      authentication = .accountCookie(secret)
    }
    let configuration = try LanzouConfiguration(authentication: authentication)
    let cookieStore = RecoverableSecretStore(base: secrets)
    let cookieKey = connection.passwordKey
    return sessionCache.value(for: connection, configuration: configuration) {
      LanzouSession(
        configuration: configuration, transport: makeHTTPTransport(),
        persistAccountCookie: { cookie in
          try cookieStore.write(Data(cookie.utf8), for: cookieKey)
        })
    }
  }
  func mobileCloudSession(for connection: Connection) throws -> MobileCloudSession {
    let credentials = MobileCloudCredentials(
      phone: connection.params["phone"] ?? "", token: try savedRemoteSecret(for: connection),
      userDomainID: connection.params["userDomainID"])
    return sessionCache.value(for: connection, configuration: credentials) {
      MobileCloudSession(credentials: credentials, transport: makeHTTPTransport())
    }
  }
  func xunleiSession(for connection: Connection) throws -> XunleiSession {
    let credentials = XunleiCredentials(accessToken: try savedRemoteSecret(for: connection))
    return sessionCache.value(for: connection, configuration: credentials) {
      XunleiSession(credentials: credentials, transport: makeHTTPTransport())
    }
  }
  func s3Transport(for connection: Connection, configuration: S3Configuration)
    -> URLSessionHTTPTransport
  {
    sessionCache.value(for: connection, configuration: configuration) { URLSessionHTTPTransport() }
  }
  func savedRemoteSecret(for connection: Connection) throws -> String {
    try RecoverableSecretStore(base: secrets).read(connection.passwordKey).map {
      String(decoding: $0, as: UTF8.self)
    } ?? ""
  }
  func oauthProfile(for connection: Connection) async throws -> OAuthProfile {
    if options.isDemo {
      return OAuthProfile(userID: "demo", nickname: "Demo", avatarURL: nil)
    }
    let provider = try await remoteProvider(for: connection)
    guard let oauth = provider as? any OAuthProfileProviding else {
      throw ConnectionError.notImplemented
    }
    do {
      try await provider.connect()
      providerAccess[connection.id] = (connection, provider.capabilities)
      let profile = try await oauth.profile()
      await provider.disconnect()
      return profile
    } catch {
      await provider.disconnect()
      throw error
    }
  }
  private func loginExpired(_ id: UUID) {
    guard let connection = connections.connections.first(where: { $0.id == id }),
      connections.states[id] != .needsLogin
    else { return }
    connections.requireLogin(id)
    writeError(L("登录已失效，请重新登录"))
    sendNotification(.loginExpired, title: L("需要重新登录"), body: connection.name)
  }
  static func deviceIdentifiers(_ devices: [(id: String, serial: String)]) -> Set<String> {
    var identifiers = Set(devices.map(\.id))
    let serials = Dictionary(grouping: devices.map(\.serial).filter { !$0.isEmpty }, by: { $0 })
    identifiers.formUnion(serials.filter { $0.value.count == 1 }.keys)
    return identifiers
  }

  private func refreshWirelessAvailability(additional: Connection? = nil) {
    var guids = Set(wirelessDiscovery.devices.filter { $0.type == .connect }.map(\.name))
    let available = ADBUSB.availableIdentifiers(in: usbDiscovery.devices)
    let serials = Set(
      usbDiscovery.devices.map(\.serial).filter { !$0.isEmpty && available.contains($0) })
    for connection in connections.connections + (additional.map { [$0] } ?? [])
    where connection.kind == .androidWiFi {
      if let guid = connection.params["guid"],
        let serial = WirelessSelection.serial(fromGUID: guid), serials.contains(serial)
      {
        guids.insert(guid)
      }
    }
    connections.wirelessGUIDsChanged(guids)
  }
  func reportMountFailure(_ message: String) {
    sendNotification(.mountFailure, title: L("挂载失败"), body: message)
  }
  private func writeError(_ message: String) {
    let directory = location.dataDirectory.appending(path: "Logs")
    Task {
      do { try await maintenance.appendError(message, at: Date(), directory: directory) } catch {
        logger.error("无法写入错误日志")
      }
    }
  }
  func showLogs() {
    let url = location.dataDirectory.appending(path: "Logs")
    Task { [self] in
      do {
        try await maintenance.prepareDirectory(url)
        system.open(url)
      } catch {
        presentOperationAlert(
          title: L("无法显示日志"), message: HumanError.detail(error),
          retryTitle: L("重试"), retry: { [weak self] in self?.showLogs() })
      }
    }
  }
  func cacheSize() async throws -> Int64 {
    let previous = await maintenance.size(at: location.cacheDirectory)
    let extensionSize = try await fileSystemCache.size()
    return previous + extensionSize
  }

  func enforceCacheLimit() async {
    let savedLimit = preferences.object(forKey: "cacheLimitGB") as? Int ?? 5
    let limit = Int64((1...50).contains(savedLimit) ? savedLimit : 5) * 1_024 * 1_024 * 1_024
    do {
      try await maintenance.enforceLimit(at: location.cacheDirectory, bytes: limit)
      if fileSystem?.hasActiveVolumesOrMounts != true {
        try await fileSystem?.beginCacheMaintenance()
        defer { fileSystem?.endCacheMaintenance() }
        try await fileSystemCache.enforceLimit(bytes: limit)
      }
    } catch {
      logger.error("无法清理缓存")
    }
  }

  func clearCache() async {
    do {
      try await fileSystem?.beginCacheMaintenance()
      defer { fileSystem?.endCacheMaintenance() }
      for connection in connections.connections where connection.kind.fileSystemScheme != nil {
        if case .mounted = connections.states[connection.id] { await connections.eject(connection) }
      }
      connections.refreshMounts()
      guard
        !connections.connections.contains(where: { connection in
          guard connection.kind.fileSystemScheme != nil else { return false }
          if case .mounted = connections.states[connection.id] { return true }
          return false
        })
      else { throw ConnectionError.busy }
      try await maintenance.clear(at: location.cacheDirectory)
      try await fileSystemCache.clear()
      connections.refreshMounts()
    } catch {
      presentOperationAlert(
        title: L("无法清除缓存"), message: HumanError.detail(error),
        retryTitle: L("重试"),
        retry: { [weak self] in
          Task { await self?.clearCache() }
        })
    }
  }

  private func presentOperationAlert(
    title: String, message: String, retryTitle: String? = nil,
    retry: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let hasRetry = retry != nil && retryTitle != nil
    let buttons = hasRetry ? [retryTitle!, L("关闭"), L("复制详细信息")] : [L("好"), L("复制详细信息")]
    system.alert(title, message, buttons) { [system] response in
      switch OperationAlertAction.resolve(response, hasRetry: hasRetry) {
      case .retry: retry?()
      case .copy: system.copy(message)
      case .dismiss: break
      }
    }
  }

  func requestNotificationAuthorization() async {
    if options.isDemo {
      notificationAuthorization = .authorized
      return
    }
    try? await system.requestNotifications()
    await refreshNotificationAuthorization()
  }

  func refreshNotificationAuthorization() async {
    guard !options.isDemo else { return }
    notificationAuthorization = await system.notificationStatus()
  }

  func openNotificationSettings() {
    guard !options.isDemo else { return }
    system.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
  }

  enum NotificationKind: String {
    case mountFailure
    case loginExpired
    case disconnect
    case deviceFound
    var preferenceKey: String {
      switch self {
      case .mountFailure: "notifications.mountFailure"
      case .loginExpired: "notifications.loginExpired"
      case .disconnect: "notifications.disconnect"
      case .deviceFound: "notifications.deviceFound"
      }
    }
  }

  // identifier 给了就用它（同一台设备的通知可以收回），category 决定通知上的按钮
  func sendNotification(
    _ kind: NotificationKind, title: String, body: String, identifier: String? = nil,
    category: String? = nil, userInfo: [String: String] = [:]
  ) {
    guard !options.isDemo else { return }
    let defaults = preferences
    if defaults.object(forKey: kind.preferenceKey) != nil,
      !defaults.bool(forKey: kind.preferenceKey)
    {
      return
    }
    Task {
      guard await system.notificationStatus() == .authorized else {
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if let category { content.categoryIdentifier = category }
      content.userInfo = userInfo
      try? await system.notify(
        UNNotificationRequest(
          identifier: identifier ?? "\(kind.rawValue)-\(UUID().uuidString)", content: content,
          trigger: nil))
    }
  }
}
