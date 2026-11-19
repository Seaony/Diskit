import Foundation

public enum HumanError {
  // 没有专门文案的 errno 用系统自己的说明（如「连接被拒绝」），不换成笼统的话
  public static func posix(_ code: Int32) -> String {
    posixMessage(code)
      ?? NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedFailureReason
      ?? String(cString: strerror(code))
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
    case .occupied where kind == .androidUSB || kind == .androidWiFi:
      L("手机的 USB 调试接口被电脑上的其它程序占用（比如 Android Studio、scrcpy），关掉它们后重试")
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
    // 认不出的错误也写上它自己的说明，不只给一个错误码
    return LF("推出失败：%@（错误码 %@）", value?.message ?? error.localizedDescription, String(code))
  }

  private struct Presentation {
    let message: String
    var code: String? = nil
    var recognized = true
    // 只写进复制的报告，不显示在界面上
    var reportCode: String? = nil
    var detail: String { code.map { "\(message) (\($0))" } ?? message }
  }

  // IOKit、OSStatus 这类错误码按十六进制查文档更方便，一起给出
  static func code(_ error: NSError) -> String {
    let value = error.code
    guard value < 0 || value > 0xFFFF else { return String(value) }
    return "\(value) (0x\(String(UInt32(truncatingIfNeeded: value), radix: 16)))"
  }

  // 「复制详细信息」的内容：界面上那句话 + 每一层错误的类型、错误域、错误码和说明 + 版本，
  // 用户发过来就能定位
  public static func report(_ error: Error, kind: ConnectionKind? = nil) -> String {
    let shown = presentation(error, kind: kind)
    var lines = [shown?.detail ?? error.localizedDescription]
    if let kind { lines.append("Kind: \(kind.rawValue)") }
    if let code = shown?.reportCode { lines.append("Code: \(code)") }
    lines.append("Error chain:")
    lines += ErrorChain.lines(error).map { "  " + $0 }
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    lines.append(
      "Diskit \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    return lines.joined(separator: "\n")
  }

  private static func presentation(_ error: Error, kind: ConnectionKind? = nil) -> Presentation? {
    var visited = Set<ObjectIdentifier>()

    func resolve(_ error: Error) -> Presentation? {
      if let mount = error as? ExtensionMountFailure { return Presentation(message: mount.record.message) }
      // 先保留明确的错误类型，不能把协议错误桥接后的 EIO 当成断开。
      if let error = error as? RemoteError {
        let message = kind.map { remote(error, kind: $0) } ?? error.localizedDescription
        switch error {
        case .posix(let code):
          return Presentation(message: message, code: "errno \(code)", recognized: posixMessage(code) != nil)
        case .http(let status): return Presentation(message: message, code: "HTTP \(status)")
        case .failed(let code, _): return Presentation(message: message, reportCode: "errno \(code)")
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
        // 错误自己带了说明（各网盘的错误类型、带原文的 NSError）就用它，errno 只用来补默认文案
        let own: String? =
          if type(of: error) == POSIXError.self { nil }
          else if let text = systemError.userInfo[NSLocalizedDescriptionKey] as? String { text }
          else if !(type(of: error) is NSError.Type) { (error as? LocalizedError)?.errorDescription }
          else { nil }
        return Presentation(message: message ?? own ?? posix(code), code: "errno \(code)",
                            recognized: own != nil || posixMessage(code) != nil)
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
      for underlying in systemError.underlyingErrors {
        if let value = resolve(underlying), value.recognized { return value }
      }
      // 认不出的错误：显示它自己的说明，不换成笼统的话；错误域和错误码在复制的报告里
      return Presentation(message: systemError.localizedDescription, recognized: false)
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
