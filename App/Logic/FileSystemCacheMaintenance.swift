import Darwin
import Foundation

actor FileSystemCacheMaintenance {
  private struct Entry {
    let url: URL
    let size: Int64
    let modified: Date
  }

  static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Containers/com.seaony.Diskit.FS/Data/Library/Caches/Diskit",
      directoryHint: .isDirectory)
  }

  private let root: URL

  init(root: URL = FileSystemCacheMaintenance.defaultRoot) {
    self.root = root
  }

  func size() throws -> Int64 {
    try totalSize(entries())
  }

  func clear() throws {
    for entry in try entries() { try FileManager.default.removeItem(at: entry.url) }
  }

  // 位置删除后调用：删掉下载缓存 Read 和本地元数据 Overlay，留下还没上传的 Writes
  func remove(connectionID: UUID) throws {
    let directory = root.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
    guard try directoryExists(directory) else { return }
    for name in ["Read", "Overlay"] {
      let url = directory.appending(path: name, directoryHint: .isDirectory)
      if try details(url) != nil { try FileManager.default.removeItem(at: url) }
    }
    // 没有待上传内容时连同空目录一起删掉
    _ = Darwin.rmdir(directory.path)
  }

  func enforceLimit(bytes limit: Int64) throws {
    guard limit >= 0 else { throw POSIXError(.EINVAL) }
    let entries = try entries().sorted {
      $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified
    }
    var total = try totalSize(entries)
    for entry in entries where total > limit {
      try FileManager.default.removeItem(at: entry.url)
      total -= entry.size
    }
  }

  private func entries() throws -> [Entry] {
    guard try directoryExists(root) else { return [] }
    let manager = FileManager.default
    var entries: [Entry] = []
    for connection in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    where UUID(uuidString: connection.lastPathComponent) != nil {
      guard try directoryExists(connection) else { continue }
      let read = connection.appending(path: "Read", directoryHint: .isDirectory)
      guard try directoryExists(read) else { continue }
      // Overlay 和 Writes 保存用户元数据与未上传内容，不能作为缓存删除。
      for file in try manager.contentsOfDirectory(at: read, includingPropertiesForKeys: nil) {
        guard let details = try details(file) else { continue }
        guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
        guard details.st_size >= 0 else { throw POSIXError(.EIO) }
        entries.append(
          Entry(
            url: file, size: details.st_size,
            modified: Date(
              timeIntervalSince1970: Double(details.st_mtimespec.tv_sec)
                + Double(details.st_mtimespec.tv_nsec) / 1_000_000_000)))
      }
    }
    return entries
  }

  private func directoryExists(_ url: URL) throws -> Bool {
    guard let details = try details(url) else { return false }
    guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw POSIXError(.ENOTDIR) }
    return true
  }

  private func details(_ url: URL) throws -> Darwin.stat? {
    var details = Darwin.stat()
    guard Darwin.lstat(url.path, &details) == 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard details.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw POSIXError(.ELOOP) }
    return details
  }

  private func totalSize(_ entries: [Entry]) throws -> Int64 {
    try entries.reduce(0) { total, entry in
      let sum = total.addingReportingOverflow(entry.size)
      guard !sum.overflow else { throw POSIXError(.EOVERFLOW) }
      return sum.partialValue
    }
  }
}
