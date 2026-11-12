import Core
import Foundation

public enum OAuthDriveError: Error, LocalizedError, LoginRequiredFailure, Sendable {
  case configuration, loginRequired, temporarilyUnavailable, invalidResponse, authorizationDenied
  public var requiresLogin: Bool {
    if case .loginRequired = self { return true }
    return false
  }
  public var errorDescription: String? {
    switch self {
    case .configuration: L("此网盘尚未在 Diskit 中启用")
    case .loginRequired: L("登录已失效，请重新登录")
    case .temporarilyUnavailable: L("服务暂时无法连接，请稍后重试")
    case .invalidResponse: L("服务返回了无法识别的数据")
    case .authorizationDenied: L("没有完成授权，请重新登录")
    }
  }
}
