import Foundation

public struct MountedShare: Equatable, Sendable {
  public var url: URL
  public var availableBytes: Int64?
  var filesystemID: Data?
  public init(url: URL, availableBytes: Int64? = nil) {
    self.url = url
    self.availableBytes = availableBytes
    filesystemID = nil
  }
}
