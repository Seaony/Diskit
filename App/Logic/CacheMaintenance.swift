import Foundation

actor CacheMaintenance {
  func prepareDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func size(at directory: URL) -> Int64 {
    files(at: directory).reduce(0) { total, file in
      let sum = total.addingReportingOverflow(file.size)
      return sum.overflow ? Int64.max : sum.partialValue
    }
  }

  func enforceLimit(at directory: URL, bytes limit: Int64) throws {
    let entries = files(at: directory).sorted { $0.modified < $1.modified }
    var total = entries.reduce(Int64(0)) { current, file in
      let sum = current.addingReportingOverflow(file.size)
      return sum.overflow ? Int64.max : sum.partialValue
    }
    for file in entries where total > limit {
      try FileManager.default.removeItem(at: file.url)
      total -= file.size
    }
  }

  func clear(at directory: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  func appendError(
    _ message: String, at date: Date, directory: URL, timeZone: TimeZone = .current
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    let file = directory.appending(path: LogDate.filename(for: date, timeZone: timeZone))
    if !FileManager.default.fileExists(atPath: file.path) {
      guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(formatter.string(from: date)) \(message)\n".utf8))
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
      if let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
        date.timeIntervalSince(modified) > 7 * 86_400 {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  private func files(at directory: URL) -> [(url: URL, size: Int64, modified: Date)] {
    guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return [] }
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return [] }
    return enumerator.compactMap { element in
      guard let url = element as? URL,
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
        values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }
  }
}
