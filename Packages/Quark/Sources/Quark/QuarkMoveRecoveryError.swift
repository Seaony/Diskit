import Core
import Foundation

struct QuarkMoveRecoveryError: Error, LocalizedError, CustomNSError {
  let original: Error
  let recovery: Error
  let temporaryName: String

  static var errorDomain: String { NSPOSIXErrorDomain }
  var errorCode: Int { Int(EIO) }
  var errorDescription: String? {
    LF("移动失败，恢复原位置也未完成。请刷新目录，检查临时文件“%@”。", temporaryName)
  }
  var errorUserInfo: [String: Any] {
    [
      NSLocalizedDescriptionKey: errorDescription ?? "",
      NSUnderlyingErrorKey: original as NSError,
      "DiskitRecoveryError": recovery as NSError,
    ]
  }
}
