import Core
import Foundation

struct QuarkMoveRecoveryError: Error, LocalizedError, CustomNSError {
  let original: Error
  let recovery: Error
  let temporaryName: String

  static var errorDomain: String { NSPOSIXErrorDomain }
  var errorCode: Int { Int(EIO) }
  var errorDescription: String? {
    // 附上移动和恢复各自失败的原因
    LF("移动失败，恢复原位置也未完成。请刷新目录，检查临时文件“%@”。", temporaryName)
      + "\n" + original.localizedDescription + "\n" + recovery.localizedDescription
  }
  var errorUserInfo: [String: Any] {
    [
      NSLocalizedDescriptionKey: errorDescription ?? "",
      NSUnderlyingErrorKey: original as NSError,
      // 日志和「复制详细信息」顺着这两个键把恢复失败的原因也展开
      NSMultipleUnderlyingErrorsKey: [recovery as NSError],
    ]
  }
}
