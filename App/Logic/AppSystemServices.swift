import AppKit
import UserNotifications

@MainActor struct AppSystemServices {
  var open: (URL) -> Void
  var copy: (String) -> Void
  var alert: (String, String, [String], @escaping (NSApplication.ModalResponse) -> Void) -> Void
  var requestNotifications: () async throws -> Void
  var notificationStatus: () async -> UNAuthorizationStatus
  var notify: (UNNotificationRequest) async throws -> Void
  // 收回已经发出去的通知（比如设备已经处理过）
  var removeNotifications: ([String]) -> Void = { _ in }

  static let live = AppSystemServices(
    open: { NSWorkspace.shared.open($0) },
    copy: {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString($0, forType: .string)
    },
    alert: { title, message, buttons, completion in
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      for title in buttons { alert.addButton(withTitle: title) }
      if let window = NSApplication.shared.keyWindow {
        alert.beginSheetModal(for: window, completionHandler: completion)
      } else {
        completion(alert.runModal())
      }
    },
    requestNotifications: {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    },
    notificationStatus: {
      await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    },
    notify: { try await UNUserNotificationCenter.current().add($0) },
    removeNotifications: {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0)
    })
}
