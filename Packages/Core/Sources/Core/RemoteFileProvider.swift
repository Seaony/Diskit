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
  case posix(Int32)
  public var errno: Int32 {
    switch self {
    case .invalidPath: EINVAL
    case .notConnected, .protocolError: EIO
    case .unauthorized: EACCES
    case .occupied: EBUSY
    case .tooLarge: EFBIG
    case .unsupported: ENOTSUP
    case .posix(let value): value
    }
  }
  public var errorDescription: String? {
    switch self {
    case .invalidPath: L("路径无效")
    case .notConnected: L("设备已断开")
    case .protocolError: L("设备返回了无效的数据")
    case .unauthorized: L("请在手机上点允许 USB 调试")
    case .occupied: L("手机正被其它 adb 程序占用，请先执行 adb kill-server")
    case .tooLarge: L("设备不支持大于 4 GB 的文件")
    case .unsupported: L("设备不支持此操作")
    case .posix(let code): String(format: L("远端操作失败（%d）"), code)
    }
  }
}
