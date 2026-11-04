import Core
import Foundation

public enum TianyiError: Error, Equatable, LocalizedError, CustomNSError, Sendable {
  case invalidCookie
  case invalidFamilyID
  case familyUnavailable
  case loginRequired
  case invalidResponse
  case service(String)

  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { Int(posixCode) }

  public var posixCode: Int32 {
    switch self {
    case .invalidCookie, .loginRequired, .familyUnavailable: EACCES
    case .invalidFamilyID: EINVAL
    case .invalidResponse, .service: EIO
    }
  }

  public var remoteError: RemoteError {
    switch self {
    case .invalidCookie, .loginRequired, .familyUnavailable: .unauthorized
    case .invalidFamilyID: .posix(EINVAL)
    case .invalidResponse, .service: .protocolError
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidCookie: L("天翼云盘登录信息无效")
    case .invalidFamilyID: L("请选择要访问的家庭云")
    case .familyUnavailable: L("当前账号没有可用的家庭云")
    case .loginRequired: L("天翼云盘登录已失效，请重新登录")
    case .invalidResponse: L("天翼云盘返回了无法识别的数据，接口可能已经变化")
    case .service(let message): String(format: L("天翼云盘操作失败：%@"), message)
    }
  }

  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? ""]
  }
}

enum TianyiHTTP {
  static func isAuthenticationFailure(_ response: HTTPResponse) -> Bool {
    if response.status == 401 { return true }
    let text = String(decoding: response.body, as: UTF8.self).lowercased()
    return text.contains("invalidsessionkey")
      || text.contains("invalidaccesstoken")
      || text.contains("usersessionbo is null")
  }

  static func check(_ response: HTTPResponse) throws {
    if isAuthenticationFailure(response) { throw RemoteError.unauthorized }
    guard (200..<300).contains(response.status) else {
      throw map(status: response.status, body: response.body)
    }
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { return }
    let reason = [
      object["errorCode"], object["errorMsg"], object["code"], object["message"],
      object["msg"], object["res_message"],
    ]
    .compactMap(string)
    .joined(separator: " ")
    .lowercased()
    if isServiceSuccess(object) { return }
    throw map(status: response.status, body: response.body, reason: reason)
  }

  static func map(status: Int, body: Data?, reason supplied: String? = nil) -> RemoteError {
    let reason: String
    if let supplied {
      reason = supplied.lowercased()
    } else if let body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    {
      reason = [
        object["errorCode"], object["errorMsg"], object["code"], object["message"],
        object["msg"], object["res_message"],
      ]
      .compactMap(string)
      .joined(separator: " ")
      .lowercased()
    } else {
      reason = String(decoding: body ?? Data(), as: UTF8.self).lowercased()
    }
    if reason.contains("invalidsessionkey") || reason.contains("invalidaccesstoken")
      || reason.contains("usersessionbo is null")
    {
      return .unauthorized
    }
    if reason.contains("filealreadyexists") || reason.contains("alreadyexists")
      || reason.contains("already exists") || reason.contains("repeatedname")
      || reason.contains("conflict")
    {
      return .posix(EEXIST)
    }
    if reason.contains("notfound") || reason.contains("not found")
      || reason.contains("notexist") || reason.contains("not exist")
      || reason.contains("nosuchfile")
    {
      return .posix(ENOENT)
    }
    if reason.contains("nospace") || reason.contains("notenoughspace")
      || reason.contains("capacit")
    {
      return .posix(ENOSPC)
    }
    if reason.contains("invalidname") || reason.contains("invalidargument") {
      return .posix(EINVAL)
    }
    switch status {
    case 400, 416: return .posix(EINVAL)
    case 401: return .unauthorized
    case 403: return .posix(EACCES)
    case 404: return .posix(ENOENT)
    case 409, 412: return .posix(EEXIST)
    case 429, 503: return .rateLimited
    case 507: return .posix(ENOSPC)
    default: return .http(status)
    }
  }

  static func transportError(_ error: Error) -> Error {
    if let error = error as? RemoteError { return error }
    if error is CancellationError { return error }
    guard let error = error as? URLError else { return RemoteError.posix(EIO) }
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

  private static func isServiceSuccess(_ object: [String: Any]) -> Bool {
    if let value = object["res_code"] {
      let code = normalized(value)
      if !code.isEmpty { return code == "0" }
    }
    if let value = object["result"] {
      let code = normalized(value)
      if !code.isEmpty { return code == "0" }
    }
    if let value = object["code"] {
      let code = normalized(value).uppercased()
      return code.isEmpty || code == "0" || code == "SUCCESS"
    }
    if let value = object["errorCode"], !normalized(value).isEmpty { return false }
    if let value = object["error"], !normalized(value).isEmpty { return false }
    return true
  }

  private static func normalized(_ value: Any) -> String {
    if let string = value as? String {
      return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let number = value as? NSNumber { return number.stringValue }
    return String(describing: value)
  }

  private static func string(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }
}
