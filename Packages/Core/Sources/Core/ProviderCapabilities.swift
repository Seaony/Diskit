import Foundation

public struct ProviderCapabilities: Sendable {
  public var canWrite: Bool
  public var canRename: Bool
  public var canMove: Bool
  public var canDelete: Bool
  public var supportsRangeRead: Bool
  // 顺序读文件时同时下载后面几段用几条连接；0 表示不预读，每次只请求要读的那一段
  public var readAheadConnections: Int
  public init(
    canWrite: Bool, canRename: Bool, canMove: Bool, canDelete: Bool, supportsRangeRead: Bool,
    readAheadConnections: Int = 0
  ) {
    self.canWrite = canWrite
    self.canRename = canRename
    self.canMove = canMove
    self.canDelete = canDelete
    self.supportsRangeRead = supportsRangeRead
    self.readAheadConnections = readAheadConnections
  }
}
