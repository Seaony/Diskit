import Foundation

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
