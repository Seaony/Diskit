import Foundation

public enum HumanError {
  public static func posix(_ code: Int32) -> String {
    posixMessage(code) ?? L("操作没有完成，请稍后重试")
  }

  private static func posixMessage(_ code: Int32) -> String? {
    switch code {
    case EIO: L("读写这个位置时出错")
    case EBUSY: L("还有程序在使用这个位置")
    case ENODEV, ENXIO, ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ENETDOWN, ENETRESET,
      ENETUNREACH:
      L("连接已断开，读不到这个位置")
    case ENOENT: L("找不到文件或位置")
    case EACCES, EPERM: L("没有访问权限")
    case EEXIST: L("同名文件已存在")
    case ENOSPC: L("存储空间不足")
    case ENOTEMPTY: L("文件夹不是空的")
    case ETIMEDOUT: L("连接超时，请检查网络后重试")
    case EROFS: L("该位置为只读")
    case ENOTSUP: L("该位置不支持此操作")
    default: nil
    }
  }

  public static func timeout(kind: ConnectionKind) -> String {
    switch kind {
    case .androidUSB: L("连接超时，请检查 USB 线缆并解锁手机后重试")
    case .cameraUSB, .ricohGR: L("连接超时，请检查 USB 线缆并打开相机后重试")
    default: L("连接超时，请检查网络后重试")
    }
  }

  public static func remote(_ error: RemoteError, kind: ConnectionKind) -> String {
    switch error {
    case .unauthorized:
      switch kind {
      case .androidUSB, .androidWiFi: L("请在手机上允许 USB 调试")
      case .ricohGR, .cameraUSB: L("请在相机上允许访问")
      case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
        .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
        L("登录已失效，请重新登录")
      default: L("没有访问权限")
      }
    case .http(401):
      switch kind {
      case .androidUSB, .androidWiFi: L("请在手机上允许 USB 调试")
      case .ricohGR, .cameraUSB: L("请在相机上允许访问")
      case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
        .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
        L("登录已失效，请重新登录")
      default: L("没有访问权限")
      }
    case .posix(ETIMEDOUT): timeout(kind: kind)
    case .http(let status): http(status)
    default:
      error.localizedDescription
    }
  }

  public static func message(
    _ error: Error, kind: ConnectionKind? = nil, fallback: String? = nil
  ) -> String {
    presentation(error, kind: kind)?.message ?? fallback ?? error.localizedDescription
  }

  public static func detail(_ error: Error) -> String {
    presentation(error)?.detail ?? error.localizedDescription
  }

  public static func detail(_ error: Error, kind: ConnectionKind) -> String {
    presentation(error, kind: kind)?.detail ?? error.localizedDescription
  }

  public static func ejectionDetail(_ error: Error) -> String {
    let value = presentation(error)
    if let value, value.recognized { return value.message }
    let systemError = error as NSError
    let code: Int
    if let connection = error as? ConnectionError, case .system(let status) = connection {
      code = Int(status)
    } else {
      code = systemError.code
    }
    return LF("推出失败（错误码 %@）", String(code))
  }

  private struct Presentation {
    let message: String
    var code: String? = nil
    var recognized = true
    var detail: String { code.map { "\(message) (\($0))" } ?? message }
  }

  private static func presentation(_ error: Error, kind: ConnectionKind? = nil) -> Presentation? {
    var visited = Set<ObjectIdentifier>()

    func resolve(_ error: Error) -> Presentation? {
      // 先保留明确的错误类型，不能把协议错误桥接后的 EIO 当成断开。
      if let error = error as? RemoteError {
        let message = kind.map { remote(error, kind: $0) } ?? error.localizedDescription
        switch error {
        case .posix(let code):
          return Presentation(message: message, code: "errno \(code)", recognized: posixMessage(code) != nil)
        case .http(let status): return Presentation(message: message, code: "HTTP \(status)")
        default: return Presentation(message: message)
        }
      }
      if let error = error as? ConnectionError {
        if case .system(let code) = error {
          return Presentation(message: posixMessage(code) ?? error.localizedDescription,
                              code: "error \(code)", recognized: posixMessage(code) != nil)
        }
        return Presentation(message: error.localizedDescription)
      }
      let systemError = error as NSError
      guard visited.insert(ObjectIdentifier(systemError)).inserted else { return nil }
      if systemError.domain == NSCocoaErrorDomain && systemError.code == NSFileManagerUnmountBusyError {
        return Presentation(message: posix(EBUSY), code: "\(systemError.domain) \(systemError.code)")
      }
      if systemError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: systemError.code) {
        let message = code == ETIMEDOUT ? kind.map { timeout(kind: $0) } : nil
        return Presentation(message: message ?? posix(code), code: "errno \(code)",
                            recognized: posixMessage(code) != nil)
      }
      if systemError.domain == NSURLErrorDomain {
        let message: String?
        switch systemError.code {
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
          message = posix(ENOTCONN)
        case NSURLErrorTimedOut:
          message = kind.map { timeout(kind: $0) } ?? posix(ETIMEDOUT)
        default: message = nil
        }
        if let message {
          return Presentation(message: message, code: "\(systemError.domain) \(systemError.code)")
        }
      }
      // Cocoa 的通用外层说明不覆盖底层已经明确的读写、占用或断开原因。
      var fallback: Presentation?
      for underlying in systemError.underlyingErrors {
        guard let value = resolve(underlying) else { continue }
        if value.recognized { return value }
        if fallback == nil { fallback = value }
      }
      return fallback
    }

    return resolve(error)
  }

  public static func http(_ status: Int) -> String {
    switch status {
    case 400: L("请求格式不正确")
    case 401: L("登录已失效，请重新登录")
    case 403: L("没有访问权限")
    case 404: L("找不到请求的内容")
    case 409, 412: L("同名文件已存在")
    case 416: L("请求的文件范围无效")
    case 429, 503: L("服务请求过多，请稍后重试")
    case 507: L("存储空间不足")
    default: L("服务暂时无法完成请求，请稍后重试")
    }
  }
}
