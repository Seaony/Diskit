import Core
import Foundation

public enum PikPakError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case invalidCredentials
  case loginRequired
  case invalidResponse
  case taskFailed
  case captchaRequired

  public var requiresLogin: Bool { self == .loginRequired }

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int {
    switch self {
    case .invalidCredentials, .loginRequired: Int(EACCES)
    case .invalidResponse, .taskFailed: Int(EIO)
    case .captchaRequired: Int(EAGAIN)
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: L("PikPak 账号或密码不正确，请重新输入")
    case .loginRequired: L("PikPak 登录已失效，请重新登录")
    case .invalidResponse: L("PikPak 返回了无法识别的数据，接口可能已经变化")
    case .taskFailed: L("PikPak 没有完成任务，请稍后重试")
    case .captchaRequired: L("PikPak 验证未通过，请稍后重试")
    }
  }

  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

enum PikPakHTTP {
  private struct APIErrorBody: Decodable {
    let error: String?
    let code: Int?
    let description: String?

    enum CodingKeys: String, CodingKey {
      case error
      case code = "error_code"
      case description = "error_description"
    }
  }

  static func check(_ response: HTTPResponse) throws {
    guard !(200..<300).contains(response.status) else { return }
    throw map(status: response.status, body: response.body)
  }

  static func isCaptchaInvalid(_ response: HTTPResponse) -> Bool {
    guard let api = try? JSONDecoder().decode(APIErrorBody.self, from: response.body) else {
      return false
    }
    return api.error?.lowercased() == "captcha_invalid" && (api.code == 9 || api.code == 4002)
  }

  static func map(status: Int, body: Data?) -> RemoteError {
    let api = body.flatMap { try? JSONDecoder().decode(APIErrorBody.self, from: $0) }
    let reason = api?.error?.lowercased() ?? ""
    if reason.contains("duplicated_name") || reason.contains("duplicate_name")
      || reason.contains("repeated_name")
    {
      return .posix(EEXIST)
    }
    if reason.contains("not_found") || reason.contains("not_exist")
      || reason.contains("file_missing")
    {
      return .posix(ENOENT)
    }
    if reason.contains("space_not_enough") || reason.contains("quota_exceeded") {
      return .posix(ENOSPC)
    }
    if reason.contains("task_daily_create_limit") || reason.contains("too_many") {
      return .rateLimited
    }
    if reason.contains("captcha_invalid") || reason.contains("name_empty")
      || reason.contains("invalid_name")
    {
      return .posix(EINVAL)
    }
    switch status {
    case 400, 416: return .posix(EINVAL)
    case 401, 403: return .posix(EACCES)
    case 404: return .posix(ENOENT)
    case 409, 412: return .posix(EEXIST)
    case 429, 503: return .rateLimited
    case 507: return .posix(ENOSPC)
    default: return .http(status)
    }
  }

  static func transportError(_ error: Error) -> Error {
    if let error = error as? RemoteError { return error }
    guard let error = error as? URLError else { return error }
    switch error.code {
    case .timedOut, .networkConnectionLost:
      return RemoteError.posix(ETIMEDOUT)
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return RemoteError.posix(ENETUNREACH)
    case .cancelled:
      return CancellationError()
    default:
      return RemoteError.posix(EIO)
    }
  }
}
