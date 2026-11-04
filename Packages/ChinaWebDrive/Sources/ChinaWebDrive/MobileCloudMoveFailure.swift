import Core
import Foundation

struct MobileCloudMoveFailure: Error, LocalizedError, CustomNSError, LoginRequiredFailure, Sendable {
  let lastConfirmedPath: String
  let original: any Error
  let recovery: any Error
  var requiresLogin: Bool {
    (original as? any LoginRequiredFailure)?.requiresLogin == true
      || (recovery as? any LoginRequiredFailure)?.requiresLogin == true
  }
  static var errorDomain: String { NSPOSIXErrorDomain }
  var errorCode: Int { Int(EIO) }
  var errorDescription: String? {
    LF("移动未完成，最后确认的位置为 %@。最终位置尚未确认，请刷新目录检查。", lastConfirmedPath)
  }
  var errorUserInfo: [String: Any] {
    [
      NSLocalizedDescriptionKey: errorDescription ?? "", NSUnderlyingErrorKey: original,
      NSLocalizedFailureReasonErrorKey: recovery.localizedDescription,
    ]
  }
}
