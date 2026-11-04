import Core
import Foundation

struct TianyiMoveRecoveryFailure: Error, LocalizedError, CustomNSError, LoginRequiredFailure {
  let lastConfirmedPath: RemotePath
  let original: Error
  let recovery: Error
  var requiresLogin: Bool {
    (original as? any LoginRequiredFailure)?.requiresLogin == true
      || (recovery as? any LoginRequiredFailure)?.requiresLogin == true
  }
  static var errorDomain: String { NSPOSIXErrorDomain }
  var errorCode: Int { Int(EIO) }
  var errorDescription: String? {
    String(
      format: L("移动未完成，且未能恢复原位置。最后确认的位置为“%@”，请在网盘中核对。原错误：%@；恢复错误：%@"), lastConfirmedPath.value,
      original.localizedDescription, recovery.localizedDescription)
  }
  var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
