import Foundation

public enum RemoteError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidPath, notConnected, protocolError, unauthorized, occupied, tooLarge, unsupported
  case rateLimited
  case http(Int)
  case posix(Int32)
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { Int(errno) }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
  public var errno: Int32 {
    switch self {
    case .invalidPath: EINVAL
    case .notConnected, .protocolError: EIO
    case .unauthorized: EACCES
    case .occupied: EBUSY
    case .tooLarge: EFBIG
    case .rateLimited: EAGAIN
    case .http(let status):
      switch status {
      case 400, 416: EINVAL
      case 401, 403: EACCES
      case 404: ENOENT
      case 408, 504: ETIMEDOUT
      case 409, 412: EEXIST
      case 429, 503: EAGAIN
      case 501, 505: ENOTSUP
      case 507: ENOSPC
      default: EIO
      }
    case .unsupported: ENOTSUP
    case .posix(let value): value
    }
  }
  public var errorDescription: String? {
    switch self {
    case .invalidPath: L("路径无效")
    case .notConnected: L("设备或服务已断开")
    case .protocolError: L("服务返回了无法识别的数据")
    case .unauthorized: L("没有访问权限")
    case .occupied: L("设备正被其它调试工具占用")
    case .tooLarge: L("设备不支持大于 4 GB 的文件")
    case .unsupported: L("设备不支持此操作")
    case .rateLimited: L("服务请求过多，请稍后重试")
    case .http(let status): HumanError.http(status)
    case .posix(let code) where code == EROFS: L("此位置为只读，不能上传、创建目录或移动文件")
    case .posix(let code): HumanError.posix(code)
    }
  }
}
