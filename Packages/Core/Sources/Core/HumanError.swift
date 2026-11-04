import Foundation

public enum HumanError {
  public static func posix(_ code: Int32) -> String {
    switch code {
    case ENOENT: L("找不到文件或位置")
    case EACCES, EPERM: L("没有访问权限")
    case EEXIST: L("同名文件已存在")
    case ENOSPC: L("存储空间不足")
    case ENOTEMPTY: L("文件夹不是空的")
    case ETIMEDOUT: L("连接超时，请检查网络后重试")
    case EROFS: L("该位置为只读")
    case ENOTSUP: L("该位置不支持此操作")
    default: L("操作没有完成，请稍后重试")
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
    case .occupied where kind == .androidUSB || kind == .androidWiFi:
      L("手机正被其它调试工具占用，请退出该工具或重新启动 Kayoi")
    case .http(401):
      switch kind {
      case .androidUSB, .androidWiFi: L("请在手机上允许 USB 调试")
      case .ricohGR, .cameraUSB: L("请在相机上允许访问")
      case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
        .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
        L("登录已失效，请重新登录")
      default: L("没有访问权限")
      }
    case .http(let status): http(status)
    default:
      error.localizedDescription
    }
  }

  public static func detail(_ error: Error) -> String {
    if let error = error as? RemoteError {
      if case .posix(let code) = error {
        return "\(error.localizedDescription) (errno \(code))"
      }
      if case .http(let status) = error {
        return "\(error.localizedDescription) (HTTP \(status))"
      }
    }
    if let error = error as? ConnectionError {
      if case .system(let code) = error {
        return "\(error.localizedDescription) (error \(code))"
      }
    }
    return error.localizedDescription
  }

  public static func detail(_ error: Error, kind: ConnectionKind) -> String {
    if let error = error as? RemoteError {
      let message = remote(error, kind: kind)
      if case .posix(let code) = error { return "\(message) (errno \(code))" }
      if case .http(let status) = error { return "\(message) (HTTP \(status))" }
      return message
    }
    return detail(error)
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
