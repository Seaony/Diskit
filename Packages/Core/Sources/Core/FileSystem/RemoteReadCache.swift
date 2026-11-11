import CryptoKit
import Foundation

// 所有卷共用同一个根目录；只淘汰下载缓存，写入暂存文件不参与淘汰。
actor RemoteReadCache {
  static let shared = RemoteReadCache()
  private var reservations: [URL: [UUID: Int64]] = [:]

  static func prefix(for path: RemotePath) -> String {
    SHA256.hash(data: Data(path.value.utf8)).map { String(format: "%02x", $0) }.joined() + "-"
  }

  static func file(root: URL, connectionID: UUID, item: RemoteItem) -> URL {
    let version = Data("\(item.size)\u{0}\(item.modified.timeIntervalSince1970)".utf8)
    let digest = SHA256.hash(data: version).map { String(format: "%02x", $0) }.joined()
    return directory(root: root, connectionID: connectionID)
      .appending(path: prefix(for: item.path) + digest + ".data")
  }

  static func directory(root: URL, connectionID: UUID) -> URL {
    root.appending(path: connectionID.uuidString).appending(path: "Read")
  }

  func read(_ file: URL, expectedSize: Int64, offset: Int64, length: Int) throws -> Data? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: file.path) else { return nil }
    do {
      let attributes = try manager.attributesOfItem(atPath: file.path)
      guard (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
        try manager.removeItem(at: file)
        return nil
      }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: length) ?? Data()
      try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return data
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }

  func reserve(root: URL, bytes: Int64, limit: Int64, id: UUID) throws {
    guard bytes >= 0, bytes <= limit else { throw RemoteError.posix(EFBIG) }
    let reserved = reservations[root, default: [:]].values.reduce(0, +)
    try trim(root: root, incoming: bytes + reserved, limit: limit)
    reservations[root, default: [:]][id] = bytes
  }

  func cancel(root: URL, id: UUID) { reservations[root]?.removeValue(forKey: id) }

  func install(_ temporary: URL, as file: URL, root: URL, limit: Int64, reservation: UUID) throws {
    let manager = FileManager.default
    let attributes = try manager.attributesOfItem(atPath: temporary.path)
    let incoming = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let reserved = reservations[root, default: [:]].filter { $0.key != reservation }.values.reduce(
      0, +)
    try trim(root: root, incoming: incoming + reserved, limit: limit, ignoring: file)
    if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
    try manager.moveItem(at: temporary, to: file)
    reservations[root]?.removeValue(forKey: reservation)
    try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
  }

  private func trim(root: URL, incoming: Int64, limit: Int64, ignoring: URL? = nil) throws {
    guard incoming <= limit else { throw RemoteError.posix(ENOSPC) }
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    var entries: [(url: URL, size: Int64, accessed: Date)] = []
    for connection in try manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    where try connection.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
      let directory = connection.appending(path: "Read")
      guard manager.fileExists(atPath: directory.path) else { continue }
      for entry in try manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]) where entry != ignoring
      {
        let values = try entry.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
        if values.isRegularFile == true {
          entries.append(
            (entry, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
      }
    }
    var total = entries.reduce(incoming) { $0 + $1.size }
    for entry in entries.sorted(by: { $0.accessed < $1.accessed }) where total > limit {
      try manager.removeItem(at: entry.url)
      total -= entry.size
    }
  }

  func invalidate(root: URL, connectionID: UUID, paths: [RemotePath]) throws {
    let directory = Self.directory(root: root, connectionID: connectionID)
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.path) else { return }
    let prefixes = paths.map(Self.prefix)
    for file in try manager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
      try manager.removeItem(at: file)
    }
  }
}
