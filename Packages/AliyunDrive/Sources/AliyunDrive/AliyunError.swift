import Core
import Foundation

public enum AliyunError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case missingConfiguration, invalidState, loginRequired, invalidResponse, rateLimited
  case authorizationFailed(Int)
  public var requiresLogin: Bool { self == .loginRequired }
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    switch self {
    case .missingConfiguration: Int(EINVAL)
    case .invalidState, .loginRequired: Int(EACCES)
    case .invalidResponse: Int(EIO)
    case .rateLimited: Int(EAGAIN)
    case .authorizationFailed(let status): Int(RemoteError.http(status).errno)
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
  public var errorDescription: String? {
    switch self {
    case .missingConfiguration: L("阿里云盘尚未在 Kayoi 中启用")
    case .invalidState: L("授权状态无效，请重新登录")
    case .loginRequired: L("阿里云盘需重新登录")
    case .invalidResponse: L("阿里云盘返回了无效的数据")
    case .rateLimited: L("阿里云盘请求过于频繁，请稍后重试")
    case .authorizationFailed(let status): LF("阿里云盘授权失败（%d）", status)
    }
  }
}
