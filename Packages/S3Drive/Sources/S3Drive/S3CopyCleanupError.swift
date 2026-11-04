import Core
import Foundation

public struct S3CopyCleanupError: Error, LocalizedError, CustomNSError {
  public let underlyingError: any Error
  public let cleanupError: any Error
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { Int(EIO) }
  public var errorDescription: String? {
    L("复制未完成，清理也失败了。原文件仍保留，请检查目标位置和未完成的分片上传。")
      + "\n" + underlyingError.localizedDescription + "\n" + cleanupError.localizedDescription
  }
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? "", NSUnderlyingErrorKey: underlyingError]
  }
}
