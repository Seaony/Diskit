import Core
import Foundation

final class XunleiPartFile: Sendable {
  let url: URL
  static let bufferSize = 128 * 1024

  init(source: URL, offset: Int64, length: Int64) throws {
    guard offset >= 0, length >= 0 else { throw RemoteError.posix(EINVAL) }
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "KayoiUpload-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    url = directory.appending(path: "part")
    do {
      guard
        FileManager.default.createFile(
          atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw RemoteError.posix(EIO) }
      let sourceHandle = try FileHandle(forReadingFrom: source)
      defer { try? sourceHandle.close() }
      let output = try FileHandle(forWritingTo: url)
      defer { try? output.close() }
      try sourceHandle.seek(toOffset: UInt64(offset))
      var remaining = length
      while remaining > 0 {
        try Task.checkCancellation()
        guard
          let data = try sourceHandle.read(upToCount: Int(min(Int64(Self.bufferSize), remaining))),
          !data.isEmpty
        else { throw RemoteError.posix(EIO) }
        try output.write(contentsOf: data)
        remaining -= Int64(data.count)
      }
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
