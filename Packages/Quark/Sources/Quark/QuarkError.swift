import Core
import Foundation

public enum QuarkError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case invalidCookie, loginRequired, invalidResponse
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var requiresLogin: Bool { self == .loginRequired }
  public var errorCode: Int { self == .invalidResponse ? Int(EIO) : Int(EACCES) }
  public var errorDescription: String? {
    switch self {
    case .invalidCookie: L("登录信息不完整，请重新扫码登录")
    case .loginRequired: L("夸克网盘需重新登录")
    case .invalidResponse: L("夸克网盘返回了无效的数据")
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
