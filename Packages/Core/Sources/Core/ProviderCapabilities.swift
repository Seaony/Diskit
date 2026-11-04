import Foundation

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
