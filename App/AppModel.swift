import ADB
import AppKit
import CameraUSB
import ChinaWebDrive
import Core
import Foundation
import LanzouDrive
import Network
import OSLog
import Observation
import PikPakDrive
import Quark
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
  @ObservationIgnored private var fileSystemStatePolling: Task<Void, Never>?
  // 正在显示扩展状态的面板、设置窗口；刚去系统设置启用扩展的截止时间
  @ObservationIgnored private var fileSystemStateViewers: Set<UUID> = []
  @ObservationIgnored private var fileSystemSettingsDeadline: ContinuousClock.Instant?
  private var refreshingFileSystemState = false
  private var extensionBlockedConnections: Set<UUID> = []
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
    if let notification = options.demoNotification {
      notificationAuthorization = notification.authorization
    }
    if options.demoLoadError { demoSetupError = L("文件无法读取，请检查访问权限") }
    connections.removed = { [weak self] id in
      guard let self else { return }
      sessionCache.remove(id)
      providerAccess.removeValue(forKey: id)
      extensionBlockedConnections.remove(id)
      updateFileSystemStatePolling()
      removeFileSystemCache(id)
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
      restartWirelessDiscoveryIfFailed()
      await connections.refreshMountSpace()
      await autoMount()
    })
  private var started = false
  private var observers: [NSObjectProtocol] = []
  private var observesFileSystemLogin = false
  // 每个位置上次看到的“没传上去的文件”数，变多了才提醒
  private var pendingUploadCounts: [UUID: Int] = [:]
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
      QuarkSession.loginInvalidatedNotification, PikPakSession.loginInvalidatedNotification,
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
    // 启动时先记下已有的数目，只对之后新出现的上传失败发通知
    for connection in connections.connections where connection.kind.fileSystemScheme != nil {
      pendingUploadCounts[connection.id] =
        PendingUploads.paths(dataDirectory: location.dataDirectory, connectionID: connection.id).count
    }
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: PendingUploads.notification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let text = notification.object as? String, let id = UUID(uuidString: text) else {
          return
        }
        Task { @MainActor in self?.pendingUploadsChanged(id) }
      })
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

  // 自动挂载逐个进行，每个位置单独登记，卡片上的“取消”只停下这一个，其余照常继续
  func autoMount() async {
    connections.refreshMounts()
    let candidates = connections.connections.filter { $0.kind.usesMount && $0.autoMount }.map(\.id)
    for id in candidates {
      guard !Task.isCancelled, !operations.isStopping else { return }
      guard let connection = connections.connections.first(where: { $0.id == id }),
        connection.kind.usesMount, connection.autoMount
      else { continue }
      let task = operations.start(connectionID: id) { [weak self] in
        await self?.connections.connectIfNeeded(connection)
      }
      await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
  }

  // 无线调试发现出错后不会自己恢复：醒来、网络恢复时重开一次。
  // 列表里还有可连接的手机时不重开：重开会先清空列表，正在用的无线手机会被当成断开推出
  private func restartWirelessDiscoveryIfFailed() {
    guard wirelessDiscovery.error != nil,
      !wirelessDiscovery.devices.contains(where: { $0.type == .connect })
    else { return }
    wirelessDiscovery.stop()
    wirelessDiscovery.start()
  }

  private func networkPathChanged(_ path: NWPath) {
    guard !operations.isStopping, lastNetworkPath != path else { return }
    lastNetworkPath = path
    if path.status != .satisfied { discovery.stop() }
    recovery.networkChanged(available: path.status == .satisfied)
  }

  func prepareToQuit() {
    stopFileSystemStatePolling()
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
      updateFileSystemStatePolling()
      if started && !options.isDemo { recovery.start() }
      logger.error("退出前推出失败：\(ErrorDiagnostics.summary(error), privacy: .public)")
      quitFailure = QuitFailure(locations: failures, reason: QuitFailure.reason(for: error))
      return false
    }
  }

  func refreshFileSystemState() async {
    guard let fileSystem, !refreshingFileSystemState, !operations.isStopping,
      !Task.isCancelled else { return }
    refreshingFileSystemState = true
    defer { refreshingFileSystemState = false }
    let state = await fileSystem.extensionStatus()
    guard !operations.isStopping, !Task.isCancelled else { return }
    let previous = fileSystemState
    fileSystemState = state
    updateFileSystemStatePolling()
    if previous == .disabled, state == .enabled { retryExtensionBlockedMounts() }
  }

  // 面板或设置窗口显示时调用：看得到扩展状态时才需要轮询
  func setFileSystemStateVisible(_ visible: Bool, viewer: UUID) {
    if visible { fileSystemStateViewers.insert(viewer) } else { fileSystemStateViewers.remove(viewer) }
    updateFileSystemStatePolling()
  }

  // 扩展没启用时，只在用户看得到状态、有位置卡在扩展上、或刚去系统设置时轮询；
  // 其他时候靠切回 Diskit 时的刷新，不在后台一直查
  private var needsFileSystemStatePolling: Bool {
    guard fileSystem != nil, fileSystemState == .disabled, !operations.isStopping else {
      return false
    }
    if !fileSystemStateViewers.isEmpty || !extensionBlockedConnections.isEmpty { return true }
    return fileSystemSettingsDeadline.map { ContinuousClock.now < $0 } ?? false
  }

  private func updateFileSystemStatePolling() {
    guard needsFileSystemStatePolling else {
      stopFileSystemStatePolling()
      return
    }
    guard fileSystemStatePolling == nil else { return }
    let wait = dependencies?.fileSystemStatePollWait ?? { try await Task.sleep(for: .seconds(2)) }
    fileSystemStatePolling = Task { [weak self] in
      while !Task.isCancelled {
        do { try await wait() } catch { return }
        guard !Task.isCancelled, let self else { return }
        guard needsFileSystemStatePolling else {
          fileSystemStatePolling = nil
          return
        }
        await refreshFileSystemState()
      }
    }
  }

  private func stopFileSystemStatePolling() {
    fileSystemStatePolling?.cancel()
    fileSystemStatePolling = nil
  }

  private func retryExtensionBlockedMounts() {
    let blocked = extensionBlockedConnections
    extensionBlockedConnections.removeAll()
    updateFileSystemStatePolling()
    let devices = Set(connections.availableAutoMountDevices.map(\.id))
    for connection in connections.connections where connection.kind.fileSystemScheme != nil {
      switch connections.states[connection.id] {
      case .failed:
        guard blocked.contains(connection.id) else { continue }
      case .mounted, .needsLogin, .connecting, .awaitingAuthorization, .ejecting:
        continue
      default:
        guard devices.contains(connection.id) else { continue }
      }
      operations.start(connectionID: connection.id) { [weak self] in
        guard let self, fileSystemState == .enabled,
          connections.connections.contains(connection) else { return }
        await connections.connectIfNeeded(connection)
      }
    }
  }

  func openFileSystemSettings() {
    guard !options.isDemo else { return }
    guard fileSystem?.openSettings() == true else {
      presentOperationAlert(title: L("无法打开系统设置"), message: L("请打开系统设置，在登录项与扩展中启用 Diskit。"))
      return
    }
    fileSystemSettingsDeadline = .now + .seconds(120)
    updateFileSystemStatePolling()
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
    connections.mountFinished = { [weak self] connection, error in
      guard let self, connection.kind.fileSystemScheme != nil else { return }
      extensionBlockedConnections.remove(connection.id)
      if case .disabled? = error as? FileSystemMountError {
        extensionBlockedConnections.insert(connection.id)
        fileSystemState = .disabled
      }
      updateFileSystemStatePolling()
    }
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

  func discardUnsavedSessions(for connection: Connection) {
    guard !connections.connections.contains(where: { $0.id == connection.id }) else { return }
    sessionCache.remove(connection.id)
    providerAccess.removeValue(forKey: connection.id)
  }

  // 登录时直接写进钥匙串的会话凭据，和 ConnectionManager.remove 删除的那几项一致
  static func sessionSecretKeys(for connection: Connection) -> [String] {
    let id = connection.id.uuidString
    switch connection.kind {
    case .quark, .ucDrive: return [id + ".cookie"]
    case .pikPak, .tianyiDrive:
      return ["\(id).oauth.\(connection.kind.rawValue)"]
    default: return []
    }
  }

  // 新位置登录过却没保存：内存里的会话和钥匙串里的登录信息一起删掉
  func discardUnsavedSecrets(for connection: Connection) {
    guard !connections.connections.contains(where: { $0.id == connection.id }) else { return }
    discardUnsavedSessions(for: connection)
    let store = RecoverableSecretStore(base: secrets)
    for key in [connection.passwordKey] + Self.sessionSecretKeys(for: connection) {
      do { try store.delete(key) } catch {
        logger.error("无法删除未保存位置的登录信息 \(ErrorDiagnostics.summary(error), privacy: .public)")
      }
    }
  }

  // 已保存的位置换账号前记下原来的登录信息（没有的记为 nil）
  func sessionSecrets(for connection: Connection) throws -> [String: Data?] {
    let store = RecoverableSecretStore(base: secrets)
    var values: [String: Data?] = [:]
    for key in Self.sessionSecretKeys(for: connection) { values.updateValue(try store.read(key), forKey: key) }
    return values
  }

  // 换了账号又没保存：把原来的登录信息写回去，丢掉按新账号建的会话
  func restoreSessionSecrets(_ values: [String: Data?], for connection: Connection) {
    guard connections.connections.contains(where: { $0.id == connection.id }) else { return }
    let store = RecoverableSecretStore(base: secrets)
    for (key, value) in values {
      do {
        if let value { try store.write(value, for: key) } else { try store.delete(key) }
      } catch {
        logger.error("无法恢复原来的登录信息 \(ErrorDiagnostics.summary(error), privacy: .public)")
      }
    }
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
  func remoteProvider(for connection: Connection) async throws -> any RemoteFileProvider {
    if let factory = dependencies?.providerFactory { return try await factory(connection) }
    guard !options.isDemo else { throw ConnectionError.notImplemented }
    switch connection.kind {
    case .androidUSB, .androidWiFi:
      return try await ADBProviderFactory.make(for: connection)
    case .cameraUSB:
      return try await CameraUSBProvider.make(
        identifier: connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    case .quark, .ucDrive:
      return QuarkProvider(session: quarkSession(for: connection))
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
          title: L("无法显示日志"), message: HumanError.detail(error), report: HumanError.report(error),
          retryTitle: L("重试"), retry: { [weak self] in self?.showLogs() })
      }
    }
  }
  func cacheSize() async throws -> Int64 {
    let previous = await maintenance.size(at: location.cacheDirectory)
    let extensionSize = try await fileSystemCache.size()
    return previous + extensionSize
  }

  // 删除位置后清掉扩展为它留的下载缓存和本地元数据；Writes 里是还没传上去的内容，留着
  // 扩展把写好的文件传不上去时（断网、空间满等），提醒用户内容还在本机、下次挂载会重试
  func pendingUploadsChanged(_ id: UUID) {
    let count = PendingUploads.paths(dataDirectory: location.dataDirectory, connectionID: id).count
    let previous = pendingUploadCounts[id] ?? 0
    pendingUploadCounts[id] = count
    guard count > previous,
      let connection = connections.connections.first(where: { $0.id == id })
    else { return }
    logger.error("有文件没传上去 id=\(id.uuidString, privacy: .public) count=\(count)")
    sendNotification(
      .uploadFailure, title: LF("“%@”有文件没传上去", connection.name),
      body: LF("%d 个文件还没传上去，下次挂载时会自动重试。", count),
      identifier: "pending-uploads-" + id.uuidString)
  }

  private func removeFileSystemCache(_ id: UUID) {
    pendingUploadCounts.removeValue(forKey: id)
    try? FileManager.default.removeItem(
      at: PendingUploads.file(dataDirectory: location.dataDirectory, connectionID: id))
    Task {
      do { try await fileSystemCache.remove(connectionID: id) } catch {
        logger.error("无法删除位置缓存 id=\(id.uuidString, privacy: .public) \(ErrorDiagnostics.summary(error), privacy: .public)")
      }
    }
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
        title: L("无法清除缓存"), message: HumanError.detail(error), report: HumanError.report(error),
        retryTitle: L("重试"),
        retry: { [weak self] in
          Task { await self?.clearCache() }
        })
    }
  }

  private func presentOperationAlert(
    title: String, message: String, report: String? = nil, retryTitle: String? = nil,
    retry: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let hasRetry = retry != nil && retryTitle != nil
    let buttons = hasRetry ? [retryTitle!, L("关闭"), L("复制详细信息")] : [L("好"), L("复制详细信息")]
    system.alert(title, message, buttons) { [system] response in
      switch OperationAlertAction.resolve(response, hasRetry: hasRetry) {
      case .retry: retry?()
      case .copy: system.copy(report ?? message)
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
    // 关系到文件会不会丢，设置里不提供开关，一直提醒
    case uploadFailure
    var preferenceKey: String {
      switch self {
      case .mountFailure: "notifications.mountFailure"
      case .loginExpired: "notifications.loginExpired"
      case .disconnect: "notifications.disconnect"
      case .deviceFound: "notifications.deviceFound"
      case .uploadFailure: "notifications.uploadFailure"
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
      logger.info("通知未发送：设置里已关闭 kind=\(kind.rawValue, privacy: .public)")
      return
    }
    Task {
      var status = await system.notificationStatus()
      if status == .notDetermined {
        // 第一次真要发通知时才向系统申请权限，用户看得出是为了什么；允许后这条接着发。
        try? await system.requestNotifications()
        status = await system.notificationStatus()
        notificationAuthorization = status
      }
      guard status == .authorized || status == .provisional else {
        logger.notice("通知未发送：系统通知未允许 kind=\(kind.rawValue, privacy: .public) status=\(status.rawValue, privacy: .public)")
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if let category { content.categoryIdentifier = category }
      content.userInfo = userInfo
      do {
        try await system.notify(
          UNNotificationRequest(
            identifier: identifier ?? "\(kind.rawValue)-\(UUID().uuidString)", content: content,
            trigger: nil))
      } catch {
        logger.error("通知发送失败 kind=\(kind.rawValue, privacy: .public) \(ErrorDiagnostics.summary(error), privacy: .public)")
      }
    }
  }
}
