import ADB
import AliyunDrive
import AppKit
import Core
import Foundation
import OSLog
import Observation
import Quark
import RicohGR
import UserNotifications

@MainActor @Observable final class AppModel {
  let connections = ConnectionManager(smb: SystemSMBService())
  let discovery = SMBDiscovery()
  let usbDiscovery = USBDiscovery()
  let wirelessDiscovery = WirelessDiscovery()
  let ricohDiscovery = RicohDiscovery()
  var pairingSelection: String?
  var forceLogin = false
  var editing: Connection?
  var alert: String?
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
    connections.testRemote = { [weak self] connection in
      let provider: any RemoteFileProvider
      switch connection.kind {
      case .androidUSB, .androidWiFi: provider = try await ADBProviderFactory.make(for: connection)
      case .ricohGR:
        provider = try await RicohProvider.make(serial: connection.params["serial"] ?? "")
      case .aliyunDrive:
        provider = AliyunProvider(
          session: AliyunSession(
            secretKey: "\(connection.id.uuidString).oauth", configuration: Self.aliyunConfiguration)
        )
      case .quark:
        provider = QuarkProvider(
          session: QuarkSession(secretKey: "\(connection.id.uuidString).cookie"))
      default: throw ConnectionError.notImplemented
      }
      do {
        try await provider.connect()
        let space = try await provider.spaceInfo()
        await provider.disconnect()
        self?.refreshWirelessAvailability(additional: connection)
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
    Task { await connections.autoMount() }
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
  private func loginExpired(_ id: UUID) {
    guard let connection = connections.connections.first(where: { $0.id == id }),
      connections.states[id] != .needsLogin
    else { return }
    connections.requireLogin(id)
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        return
      }
      let content = UNMutableNotificationContent()
      content.title = L("需重新登录")
      content.body = connection.name
      try? await center.add(
        UNNotificationRequest(identifier: "login-" + id.uuidString, content: content, trigger: nil))
    }
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
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        return
      }
      let content = UNMutableNotificationContent()
      content.title = L("挂载失败")
      content.body = message
      try? await center.add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
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
    } catch { alert = error.localizedDescription }
  }
  func showHelp() {
    guard let url = Bundle.main.url(forResource: "README", withExtension: "md") else { return }
    NSWorkspace.shared.open(url)
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
  func clearCache() async {
    do {
      for connection in connections.connections {
        if case .mounted = connections.states[connection.id] {
          await connections.toggle(connection)
        }
      }
      connections.refreshMounts()
      guard connections.mountedCount == 0 else { throw ConnectionError.busy }
      if FileManager.default.fileExists(atPath: location.cacheDirectory.path) {
        try FileManager.default.removeItem(at: location.cacheDirectory)
      }
    } catch { alert = error.localizedDescription }
  }
}
