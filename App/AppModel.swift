import ADB
import AliyunDrive
import AppKit
import CameraUSB
import ChinaWebDrive
import CloudDrive
import Core
import Foundation
import LanzouDrive
import OSLog
import Observation
import PikPakDrive
import Quark
import RicohGR
import S3Drive
import TianyiDrive
import UserNotifications

@MainActor @Observable final class AppModel {
  let connections = ConnectionManager(smb: SystemSMBService())
  let discovery = SMBDiscovery()
  let usbDiscovery = USBDiscovery()
  let wirelessDiscovery = WirelessDiscovery()
  let ricohDiscovery = RicohDiscovery()
  let cameraUSBDiscovery = CameraUSBDiscovery()
  var pairingSelection: String?
  var forceLogin = false
  var editing: Connection?
  var notificationAuthorization: UNAuthorizationStatus = .notDetermined
  private var started = false
  private var observers: [NSObjectProtocol] = []
  private let logger = Logger(subsystem: "com.seaony.Kayoi", category: "connections")
  private let location = LocalStorageLocation()
  func start() {
    guard !started else { return }
    started = true
    connections.openInFinder = { NSWorkspace.shared.open($0) }
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
        body: String.localizedStringWithFormat(L("“%@”的连接已断开。"), connection.name))
    }
    connections.testRemote = { [weak self] connection in
      guard let self else { throw ConnectionError.notImplemented }
      let provider = try await self.remoteProvider(for: connection)
      do {
        try await provider.connect()
        let space: SpaceInfo
        do {
          space = try await provider.spaceInfo()
        } catch RemoteError.unsupported
          where connection.kind == .lanzou
          || connection.kind == .cameraUSB
        {
          space = SpaceInfo(total: 0, used: 0)
        }
        await provider.disconnect()
        self.refreshWirelessAvailability(additional: connection)
        return space
      } catch {
        await provider.disconnect()
        throw error
      }
    }
    usbDiscovery.changed = { [weak self] devices in
      self?.connections.usbDevicesChanged(serials: Set(devices.map(\.serial)))
      self?.refreshWirelessAvailability()
    }
    wirelessDiscovery.changed = { [weak self] _ in self?.refreshWirelessAvailability() }
    wirelessDiscovery.start()
    usbDiscovery.start()
    ricohDiscovery.changed = { [weak self] devices in
      self?.connections.ricohDevicesChanged(serials: Set(devices.map(\.serial)))
    }
    ricohDiscovery.start()
    cameraUSBDiscovery.changed = { [weak self] devices in
      self?.connections.cameraUSBDevicesChanged(serials: Set(devices.map(\.serial)))
    }
    cameraUSBDiscovery.start()
    discovery.start()
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in
          Task { @MainActor in self?.connections.refreshMounts() }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AliyunSession.loginInvalidatedNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let key = notification.userInfo?["secretKey"] as? String,
          let id = UUID(uuidString: String(key.prefix(36)))
        else { return }
        Task { @MainActor in self?.loginExpired(id) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: QuarkSession.loginInvalidatedNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let key = notification.userInfo?["secretKey"] as? String,
          let id = UUID(uuidString: String(key.prefix(36)))
        else { return }
        Task { @MainActor in self?.loginExpired(id) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: OAuthSession.invalidationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let key = notification.userInfo?["secretKey"] as? String,
          let id = UUID(uuidString: String(key.prefix(36)))
        else { return }
        Task { @MainActor in self?.loginExpired(id) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: PikPakSession.loginInvalidatedNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let key = notification.userInfo?["secretKey"] as? String,
          let id = UUID(uuidString: String(key.prefix(36)))
        else { return }
        Task { @MainActor in self?.loginExpired(id) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: TianyiSession.loginInvalidatedNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let key = notification.userInfo?["secretKey"] as? String,
          let id = UUID(uuidString: String(key.prefix(36)))
        else { return }
        Task { @MainActor in self?.loginExpired(id) }
      })
    Task { await connections.autoMount() }
    Task { await refreshNotificationAuthorization() }
    enforceCacheLimit()
  }
  static var aliyunConfiguration: AliyunConfiguration {
    let info = Bundle.main.infoDictionary ?? [:]
    return AliyunConfiguration(
      clientID: info["ALIYUN_CLIENT_ID"] as? String ?? "",
      clientSecret: info["ALIYUN_CLIENT_SECRET"] as? String ?? "",
      redirectURI: info["ALIYUN_REDIRECT_URI"] as? String ?? "")
  }
  func aliyunSession(for connection: Connection) -> AliyunSession {
    AliyunSession(
      secretKey: "\(connection.id.uuidString).oauth", configuration: Self.aliyunConfiguration)
  }
  func pikPakSession(for connection: Connection) -> PikPakSession {
    PikPakSession(secretKey: "\(connection.id.uuidString).oauth.pikPak")
  }
  func tianyiSession(for connection: Connection) -> TianyiSession {
    let familyID = connection.params["familyID"] ?? ""
    let configuration =
      connection.params["scope"] == "family"
      ? TianyiConfiguration.family(familyID: familyID) : TianyiConfiguration.personal
    return TianyiSession(
      secretKey: "\(connection.id.uuidString).oauth.tianyiDrive", configuration: configuration)
  }
  func oauthConfiguration(for kind: ConnectionKind) -> OAuthConfiguration? {
    let info = Bundle.main.infoDictionary ?? [:]
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
        clientSecret: value("ONEDRIVE_CLIENT_SECRET"),
        authorizationURL: URL(
          string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        redirectURI: value("ONEDRIVE_REDIRECT_URI"),
        scopes: ["offline_access", "User.Read", "Files.ReadWrite"], usesPKCE: true)
    case .googleDrive:
      return OAuthConfiguration(
        clientID: value("GOOGLE_CLIENT_ID"),
        clientSecret: value("GOOGLE_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        redirectURI: value("GOOGLE_REDIRECT_URI"),
        scopes: [
          "openid", "email", "profile", "https://www.googleapis.com/auth/drive",
        ],
        additionalAuthorizationItems: ["access_type": "offline", "prompt": "consent"],
        usesPKCE: true)
    case .dropbox:
      return OAuthConfiguration(
        clientID: value("DROPBOX_CLIENT_ID"),
        clientSecret: value("DROPBOX_CLIENT_SECRET"),
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
    return kind != .baiduDrive
      || !(Bundle.main.infoDictionary?["BAIDU_APP_ID"] as? String ?? "").isEmpty
  }
  func oauthSession(for connection: Connection) throws -> OAuthSession {
    guard oauthIsConfigured(for: connection.kind),
      let configuration = oauthConfiguration(for: connection.kind)
    else { throw OAuthDriveError.configuration }
    return OAuthSession(
      configuration: configuration,
      secretKey: "\(connection.id.uuidString).oauth.\(connection.kind.rawValue)")
  }
  func remoteProvider(for connection: Connection) async throws -> any RemoteFileProvider {
    switch connection.kind {
    case .androidUSB, .androidWiFi:
      return try await ADBProviderFactory.make(for: connection)
    case .ricohGR:
      return try await RicohProvider.make(serial: connection.params["serial"] ?? "")
    case .cameraUSB:
      return try await CameraUSBProvider.make(identifier: connection.params["serial"] ?? "")
    case .aliyunDrive:
      return AliyunProvider(session: aliyunSession(for: connection))
    case .quark:
      return QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", configuration: .quark))
    case .ucDrive:
      return QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", configuration: .uc))
    case .baiduDrive:
      let root = Bundle.main.infoDictionary?["BAIDU_ROOT_PATH"] as? String ?? "apps/Kayoi"
      let appID = Bundle.main.infoDictionary?["BAIDU_APP_ID"] as? String ?? ""
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
      return LanzouProvider(
        configuration: try LanzouConfiguration(authentication: authentication))
    case .mobileCloud:
      return MobileCloudProvider(
        session: MobileCloudSession(
          credentials: MobileCloudCredentials(
            phone: connection.params["phone"] ?? "",
            token: try savedRemoteSecret(for: connection),
            userDomainID: connection.params["userDomainID"])))
    case .thunderDrive:
      return XunleiProvider(
        session: XunleiSession(
          credentials: XunleiCredentials(
            accessToken: try savedRemoteSecret(for: connection))))
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      guard let endpoint = URL(string: connection.params["endpoint"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      let secret =
        try LoginKeychainStore().read(connection.passwordKey).map {
          String(decoding: $0, as: UTF8.self)
        } ?? ""
      return S3Provider(
        configuration: S3Configuration(
          endpoint: endpoint, region: connection.params["region"] ?? "us-east-1",
          bucket: connection.params["bucket"] ?? "",
          accessKey: connection.params["accessKey"] ?? "", secretKey: secret,
          pathStyle: connection.params["pathStyle"] != "false"))
    default:
      throw ConnectionError.notImplemented
    }
  }
  func savedRemoteSecret(for connection: Connection) throws -> String {
    try LoginKeychainStore().read(connection.passwordKey).map {
      String(decoding: $0, as: UTF8.self)
    } ?? ""
  }
  func oauthProfile(for connection: Connection) async throws -> OAuthProfile {
    let provider = try await remoteProvider(for: connection)
    guard let oauth = provider as? any OAuthProfileProviding else {
      throw ConnectionError.notImplemented
    }
    do {
      try await provider.connect()
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
  private func refreshWirelessAvailability(additional: Connection? = nil) {
    var guids = Set(wirelessDiscovery.devices.filter { $0.type == .connect }.map(\.name))
    let serials = Set(usbDiscovery.devices.map(\.serial))
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
    do {
      let folder = location.dataDirectory.appending(path: "Logs")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let formatter = ISO8601DateFormatter()
      let now = Date()
      let date = String(formatter.string(from: now).prefix(10))
      let url = folder.appending(path: date + ".log")
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("\(formatter.string(from: now)) \(message)\n".utf8))
      for file in try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
      {
        if let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
          now.timeIntervalSince(modified) > 7 * 86_400
        {
          try FileManager.default.removeItem(at: file)
        }
      }
    } catch { logger.error("无法写入错误日志") }
  }
  func showLogs() {
    let url = location.dataDirectory.appending(path: "Logs")
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
    } catch {
      presentOperationAlert(
        title: L("无法显示日志"), message: HumanError.detail(error),
        retryTitle: L("重试"), retry: { [weak self] in self?.showLogs() })
    }
  }
  func cacheSize() -> Int64 {
    guard
      let files = FileManager.default.enumerator(
        at: location.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var count: Int64 = 0
    for case let file as URL in files {
      if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true
      {
        count += Int64(values.fileSize ?? 0)
      }
    }
    return count
  }

  func enforceCacheLimit() {
    let limit =
      Int64(UserDefaults.standard.object(forKey: "cacheLimitGB") as? Int ?? 5)
      * 1_024 * 1_024 * 1_024
    guard
      let enumerator = FileManager.default.enumerator(
        at: location.cacheDirectory,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    var files: [(url: URL, size: Int64, modified: Date)] = []
    var total: Int64 = 0
    for case let file as URL in enumerator {
      guard
        let values = try? file.resourceValues(
          forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
        values.isRegularFile == true
      else { continue }
      let size = Int64(values.fileSize ?? 0)
      total += size
      files.append((file, size, values.contentModificationDate ?? .distantPast))
    }
    guard total > limit else { return }
    for file in files.sorted(by: { $0.modified < $1.modified }) {
      guard total > limit else { break }
      if (try? FileManager.default.removeItem(at: file.url)) != nil {
        total -= file.size
      }
    }
  }
  func clearCache() async {
    do {
      for connection in connections.connections where connection.usesFileSystemCache {
        if case .mounted = connections.states[connection.id] {
          await connections.toggle(connection)
        }
      }
      connections.refreshMounts()
      let cachedMountsRemain = connections.connections.contains { connection in
        guard connection.usesFileSystemCache else { return false }
        if case .mounted = connections.states[connection.id] { return true }
        return false
      }
      guard !cachedMountsRemain else { throw ConnectionError.busy }
      if FileManager.default.fileExists(atPath: location.cacheDirectory.path) {
        try FileManager.default.removeItem(at: location.cacheDirectory)
      }
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
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    if retry != nil, let retryTitle {
      alert.addButton(withTitle: retryTitle)
      alert.addButton(withTitle: L("关闭"))
    } else {
      alert.addButton(withTitle: L("好"))
    }
    alert.addButton(withTitle: L("复制详细信息"))
    let completion: (NSApplication.ModalResponse) -> Void = { response in
      if response == .alertFirstButtonReturn, let retry {
        retry()
      } else if response == .alertSecondButtonReturn, retry != nil {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
      } else if response == .alertSecondButtonReturn, retry == nil {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
      }
    }
    if let window = NSApplication.shared.keyWindow {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  func requestNotificationAuthorization() async {
    let center = UNUserNotificationCenter.current()
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    await refreshNotificationAuthorization()
  }

  func refreshNotificationAuthorization() async {
    notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings()
      .authorizationStatus
  }

  func openNotificationSettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
  }

  private enum NotificationKind: String {
    case mountFailure
    case loginExpired
    case disconnect
    var preferenceKey: String {
      switch self {
      case .mountFailure: "notifications.mountFailure"
      case .loginExpired: "notifications.loginExpired"
      case .disconnect: "notifications.disconnect"
      }
    }
  }

  private func sendNotification(_ kind: NotificationKind, title: String, body: String) {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: kind.preferenceKey) != nil,
      !defaults.bool(forKey: kind.preferenceKey)
    {
      return
    }
    Task {
      let center = UNUserNotificationCenter.current()
      guard await center.notificationSettings().authorizationStatus == .authorized else {
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      try? await center.add(
        UNNotificationRequest(
          identifier: "\(kind.rawValue)-\(UUID().uuidString)", content: content, trigger: nil))
    }
  }
}
