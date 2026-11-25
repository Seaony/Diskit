import Foundation

public enum FileSystemLoginEvent {
  public static let notification = Notification.Name("com.seaony.Diskit.fileSystemLoginExpired")

  public static func supports(kind: ConnectionKind) -> Bool {
    switch kind {
    case .quark, .ucDrive, .pikPak, .tianyiDrive, .mobileCloud, .thunderDrive, .lanzou:
      true
    default: false
    }
  }

  public static func requiresLogin(_ error: Error, kind: ConnectionKind) -> Bool {
    guard supports(kind: kind), !NetworkFailure.isTransportError(error) else { return false }
    if let failure = error as? any LoginRequiredFailure { return failure.requiresLogin }
    if let remote = error as? RemoteError {
      switch remote {
      case .unauthorized, .http(401): return true
      default: break
      }
    }
    return false
  }

  public static func postIfNeeded(_ error: Error, connection: Connection) {
    guard requiresLogin(error, kind: connection.kind) else { return }
    // 沙盒通知只带连接标识，不带凭据或字典。
    DistributedNotificationCenter.default().postNotificationName(
      notification, object: connection.id.uuidString, userInfo: nil, deliverImmediately: true)
  }
}
