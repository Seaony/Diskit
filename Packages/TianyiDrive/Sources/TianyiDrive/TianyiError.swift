import Core
import Foundation

public enum TianyiError: Error, Equatable, LocalizedError, CustomNSError, LoginRequiredFailure,
  Sendable
{
  case invalidCookie
  case invalidFamilyID
  case familyUnavailable
  case loginRequired
  case invalidResponse
  case service(String)

  public var requiresLogin: Bool { self == .loginRequired }

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
    case .invalidResponse: .protocolError
    case .service: .failed(EIO, errorDescription ?? "")
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidCookie: L("天翼云盘登录信息无效")
    case .invalidFamilyID: L("请选择要访问的家庭云")
    case .familyUnavailable: L("当前账号没有可用的家庭云")
    case .loginRequired: L("天翼云盘登录已失效，请重新登录")
    case .invalidResponse: L("天翼云盘返回了无法识别的数据，接口可能已经变化")
    case .service(let message): LF("天翼云盘操作失败：%@", message)
    }
  }

  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? ""]
  }
}

enum TianyiHTTP {
  static func isAuthenticationFailure(_ response: HTTPResponse) -> Bool {
    if response.status >= 500 || response.status == 429 || isVerificationChallenge(response) {
      return false
    }
    if response.status == 401 { return true }
    let text = reason(in: response.body)
    return text.contains("invalidsessionkey")
      || text.contains("invalidaccesstoken")
      || text.contains("usersessionbo is null")
  }

  static func check(_ response: HTTPResponse) throws {
    do {
      if isVerificationChallenge(response) { throw TianyiError.service("需要在天翼云盘网页完成验证") }
      if isAuthenticationFailure(response) { throw RemoteError.unauthorized }
      guard (200..<300).contains(response.status) else {
        throw map(status: response.status, body: response.body)
      }
      guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
      else { return }
      if isServiceSuccess(object) { return }
      throw map(status: response.status, body: response.body, reason: reason(in: object))
    } catch {
      if (200..<300).contains(response.status) {
        PackageDiagnostics.failure(error, category: .tianyiDrive, operation: .request)
      }
      throw error
    }
  }

  static func map(status: Int, body: Data?, reason supplied: String? = nil) -> RemoteError {
    if status == 429 || status == 503 { return .rateLimited }
    if status >= 500 { return serviceFailure(status: status, body: body) }
    if isVerificationChallenge(HTTPResponse(status: status, body: body ?? Data())) {
      return .posix(EAGAIN)
    }
    let reason = supplied?.lowercased() ?? Self.reason(in: body ?? Data())
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
    default: return serviceFailure(status: status, body: body)
    }
  }

  // 状态码说明不了原因时，把天翼云盘的原话和错误码照实写出来；不是 JSON 的才只报状态码
  private static func serviceFailure(status: Int, body: Data?) -> RemoteError {
    guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return .http(status) }
    func first(_ keys: [String]) -> String? {
      keys.lazy.compactMap { string(object[$0])?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }
    let said = first(["res_message", "errorMsg", "message", "msg", "error_description"])
    let code = first(["res_code", "result", "errorCode", "code", "error"])
    let posixCode = RemoteError.http(status).errno
    switch (said, code) {
    case (let said?, let code?):
      return .failed(
        posixCode, LF("天翼云盘返回错误：%@（错误码 %@，HTTP %@）", said, code, String(status)))
    case (let said?, nil), (nil, let said?):
      return .failed(posixCode, LF("天翼云盘返回错误：%@（HTTP %@）", said, String(status)))
    case (nil, nil):
      return .http(status)
    }
  }

  static func transportError(_ error: Error) -> Error {
    if let error = error as? RemoteError { return error }
    if error is CancellationError { return error }
    guard let error = error as? URLError else {
      // 系统网络错误按原错误码转换；其他错误报出它自己的说明
      if NetworkFailure.isTransportError(error) || (error as NSError).domain == NSPOSIXErrorDomain {
        return NetworkFailure.posix(error)
      }
      return RemoteError.failed(EIO, LF("天翼云盘请求失败：%@", error.localizedDescription))
    }
    switch error.code {
    case .timedOut, .networkConnectionLost:
      return RemoteError.posix(ETIMEDOUT)
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return RemoteError.posix(ENETUNREACH)
    case .cancelled:
      return CancellationError()
    default:
      return RemoteError.failed(
        EIO,
        LF(
          "连接天翼云盘失败：%@（URLError %@）", error.localizedDescription,
          String(error.code.rawValue)))
    }
  }

  private static func isVerificationChallenge(_ response: HTTPResponse) -> Bool {
    let text = reason(in: response.body)
    return ["captcha", "riskcontrol", "risk_control", "验证码", "风控"].contains { text.contains($0) }
  }

  // JSON 只看错误码和提示字段：成功的文件列表里文件名可能恰好带这些词。
  // 不是 JSON 的（比如验证网页）才看整段内容。
  private static func reason(in body: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      return reason(in: object)
    }
    return String(decoding: body, as: UTF8.self).lowercased()
  }

  private static func reason(in object: [String: Any]) -> String {
    [
      object["res_code"], object["res_message"], object["errorCode"], object["errorMsg"],
      object["code"], object["message"], object["msg"], object["error"],
    ]
    .compactMap(string)
    .joined(separator: " ")
    .lowercased()
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
