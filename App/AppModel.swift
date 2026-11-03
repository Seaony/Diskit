import AppKit
import Core
import Foundation
import OSLog
import Observation
import UserNotifications

@MainActor @Observable final class AppModel {
  let connections = ConnectionManager(smb: SystemSMBService())
  let discovery = SMBDiscovery()
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
    connections.mountFailed = { [weak self] message in self?.reportMountFailure(message) }
    discovery.start()
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in
          Task { @MainActor in self?.connections.refreshMounts() }
        })
    }
    Task { await connections.autoMount() }
  }
  func reportMountFailure(_ message: String) {
    logger.error("挂载失败：\(message, privacy: .public)")
    writeError(message)
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
