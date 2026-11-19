import Foundation

public enum RemoteError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidPath, notConnected, protocolError, unauthorized, occupied, tooLarge, unsupported
  case rateLimited
  case http(Int)
  case posix(Int32)
  // 说得清原因的失败：reason 直接给人看，写清哪一步、对方返回了什么、系统错误码；
  // errno 只给 Finder 和系统用。不要再把具体原因压成一个笼统的 EIO
  case failed(Int32, String)
  // 对方返回的数据不对（解析不了、缺字段）：和 protocolError 一样按断线处理、会重连，但带上具体哪里不对
  case malformed(String)
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { Int(errno) }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
  public var errno: Int32 {
    switch self {
    case .invalidPath: EINVAL
    case .notConnected, .protocolError, .malformed: EIO
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
    case .failed(let value, _): value
    }
  }
  public var errorDescription: String? {
    switch self {
    case .invalidPath: L("路径无效")
    case .notConnected: HumanError.posix(ENOTCONN)
    case .protocolError: L("服务返回了无法识别的数据")
    case .unauthorized: L("没有访问权限")
    case .occupied: HumanError.posix(EBUSY)
    case .tooLarge: L("设备不支持大于 4 GB 的文件")
    case .unsupported: L("设备不支持此操作")
    case .rateLimited: L("服务请求过多，请稍后重试")
    case .http(let status): HumanError.http(status)
    case .posix(let code) where code == EROFS: L("此位置为只读，不能上传、创建目录或移动文件")
    case .posix(let code): HumanError.posix(code)
    case .failed(_, let reason): reason
    case .malformed(let reason): reason
    }
  }
}
