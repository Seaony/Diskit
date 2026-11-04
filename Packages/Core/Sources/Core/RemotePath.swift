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

extension RemotePath {
  private init(normalized value: String) { self.value = value }

  public var parent: RemotePath {
    RemotePath(normalized: "/" + value.split(separator: "/").dropLast().joined(separator: "/"))
  }

  public var basename: String { value.split(separator: "/").last.map(String.init) ?? "" }
}
