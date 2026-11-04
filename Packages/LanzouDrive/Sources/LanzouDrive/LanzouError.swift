import Core
import Foundation

public enum LanzouError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case invalidConfiguration
  case authenticationRequired
  case authenticationExpired
  case passwordRequired
  case invalidPassword
  case notFound
  case rateLimited
  case antiBotChallenge
  case invalidResponse
  case rangeUnsupported
  case http(Int)
  case service(String)

  public var requiresLogin: Bool {
    self == .authenticationRequired || self == .authenticationExpired
  }

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { Int(posixCode) }

  public var posixCode: Int32 {
    switch self {
    case .invalidConfiguration: EINVAL
    case .authenticationRequired, .authenticationExpired, .passwordRequired, .invalidPassword:
      EACCES
    case .notFound: ENOENT
    case .rateLimited: EAGAIN
    case .invalidResponse, .antiBotChallenge, .service: EIO
    case .rangeUnsupported: ENOTSUP
    case .http(let status):
      switch status {
      case 400, 416: EINVAL
      case 401, 403: EACCES
      case 404: ENOENT
      case 409, 412: EEXIST
      case 429, 503: EAGAIN
      case 507: ENOSPC
      default: EIO
      }
    }
  }

  public var remoteError: RemoteError {
    switch self {
    case .invalidConfiguration, .invalidResponse: .protocolError
    case .authenticationRequired, .authenticationExpired, .passwordRequired, .invalidPassword:
      .unauthorized
    case .notFound: .posix(ENOENT)
    case .rateLimited: .rateLimited
    case .antiBotChallenge, .service: .protocolError
    case .rangeUnsupported: .unsupported
    case .http(let status): .http(status)
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: L("蓝奏云连接配置无效")
    case .authenticationRequired: L("蓝奏云需要登录或分享密码")
    case .authenticationExpired: L("蓝奏云登录已失效，请更新登录信息")
    case .passwordRequired: L("这个分享需要密码")
    case .invalidPassword: L("蓝奏云分享密码错误")
    case .notFound: L("找不到蓝奏云文件或分享")
    case .rateLimited: L("蓝奏云请求过于频繁，请稍后重试")
    case .antiBotChallenge: L("蓝奏云要求浏览器验证，请在浏览器中完成验证后更新登录信息")
    case .invalidResponse: L("蓝奏云返回了无法识别的数据")
    case .rangeUnsupported: L("蓝奏云下载服务没有返回请求的文件范围")
    case .http(let status): HumanError.http(status)
    case .service(let message): LF("蓝奏云操作失败：%@", message)
    }
  }

  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? ""]
  }

  static func fromHTTP(_ status: Int) -> LanzouError {
    switch status {
    case 401, 403: .http(status)
    case 404: .notFound
    case 429, 503: .rateLimited
    default: .http(status)
    }
  }
}
