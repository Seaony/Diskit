import Foundation

public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
  public let value: String
  public init(_ value: String) throws {
    guard value.hasPrefix("/"), !value.contains("\0"), !value.split(separator: "/").contains("..")
    else { throw RemoteError.invalidPath }
    self.value = "/" + value.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
  }
  public var description: String { value }
  public func appending(_ name: String) throws -> RemotePath {
    guard !name.contains("/"), name != ".", name != ".." else { throw RemoteError.invalidPath }
    return try RemotePath((value == "/" ? "" : value) + "/" + name)
  }
}

public struct ProviderCapabilities: Sendable {
  public var canWrite: Bool
  public var canRename: Bool
  public var canMove: Bool
  public var canDelete: Bool
  public var supportsRangeRead: Bool
  public init(
    canWrite: Bool, canRename: Bool, canMove: Bool, canDelete: Bool, supportsRangeRead: Bool
  ) {
    self.canWrite = canWrite
    self.canRename = canRename
    self.canMove = canMove
    self.canDelete = canDelete
    self.supportsRangeRead = supportsRangeRead
  }
}

public struct SpaceInfo: Sendable, Equatable {
  public let total: Int64
  public let used: Int64
  public var available: Int64 { total - used }
  public init(total: Int64, used: Int64) {
    self.total = total
    self.used = used
  }
}

public struct RemoteItem: Sendable, Equatable {
  public var path: RemotePath
  public var name: String
  public var isDirectory: Bool
  public var size: Int64
  public var modified: Date
  public init(path: RemotePath, name: String, isDirectory: Bool, size: Int64, modified: Date) {
    self.path = path
    self.name = name
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
  }
}

public protocol RemoteFileProvider: Sendable {
  var capabilities: ProviderCapabilities { get }
  func connect() async throws
  func disconnect() async
  func spaceInfo() async throws -> SpaceInfo
  func list(_ path: RemotePath) async throws -> [RemoteItem]
  func stat(_ path: RemotePath) async throws -> RemoteItem
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  >
  func write(_ path: RemotePath, from localFile: URL) async throws
  func makeDirectory(_ path: RemotePath) async throws
  func remove(_ path: RemotePath, recursive: Bool) async throws
  func move(_ from: RemotePath, to: RemotePath) async throws
}

public enum RemoteError: Error, Equatable, LocalizedError, Sendable {
  case invalidPath, notConnected, protocolError, unauthorized, occupied, tooLarge, unsupported
  case rateLimited
  case http(Int)
  case posix(Int32)
  public var errno: Int32 {
    switch self {
    case .invalidPath: EINVAL
    case .notConnected, .protocolError: EIO
    case .unauthorized: EACCES
    case .occupied: EBUSY
    case .tooLarge: EFBIG
    case .rateLimited: EAGAIN
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
    case .unsupported: ENOTSUP
    case .posix(let value): value
    }
  }
  public var errorDescription: String? {
    switch self {
    case .invalidPath: L("路径无效")
    case .notConnected: L("设备或服务已断开")
    case .protocolError: L("服务返回了无法识别的数据")
    case .unauthorized: L("没有访问权限")
    case .occupied: L("设备正被其它调试工具占用")
    case .tooLarge: L("设备不支持大于 4 GB 的文件")
    case .unsupported: L("设备不支持此操作")
    case .rateLimited: L("服务请求过多，请稍后重试")
    case .http(let status): HumanError.http(status)
    case .posix(let code) where code == EROFS: L("此位置为只读，不能上传、创建目录或移动文件")
    case .posix(let code): HumanError.posix(code)
    }
  }
}

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
