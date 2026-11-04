import Foundation

public enum HTTPContentRange {
  public static func matches(_ header: String?, requested: Range<Int64>, size: Int64) -> Bool {
    guard let header, header.hasPrefix("bytes ") else { return false }
    let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard fields.count == 2, Int64(fields[1]) == size else { return false }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }
}
