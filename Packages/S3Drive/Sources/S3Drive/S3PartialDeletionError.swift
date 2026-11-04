import Core
import Foundation

// 已收到成功响应的删除无法回滚；失败对象的远端状态需要重新读取。
public struct S3PartialDeletionError: Error, LocalizedError, CustomNSError {
  public let deletedKeys: [String]
  public let uncertainKey: String
  public let unattemptedKeys: [String]
  public let underlyingError: any Error

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    if underlyingError is CancellationError { return Int(ECANCELED) }
    let error = underlyingError as NSError
    return error.domain == NSPOSIXErrorDomain ? error.code : Int(EIO)
  }
  public var errorDescription: String? {
    LF("删除未完成：已确认删除 %lld / %lld 个对象，失败对象的状态尚未确认。请刷新后检查剩余内容。",
      Int64(deletedKeys.count), Int64(deletedKeys.count + unattemptedKeys.count + 1))
      + "\n" + underlyingError.localizedDescription
  }
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? "", NSUnderlyingErrorKey: underlyingError]
  }
}
