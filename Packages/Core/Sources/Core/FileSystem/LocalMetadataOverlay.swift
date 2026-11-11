import Darwin
import Foundation

public struct LocalMetadataOverlay: Sendable {
  private static let reservedNames: Set<String> = [
    ".DS_Store", ".VolumeIcon.icns", ".Spotlight-V100", ".fseventsd", ".Trashes",
  ]
  private let root: URL
  private var files: URL { root.appending(path: "Files", directoryHint: .isDirectory) }
  private var attributesFile: URL { root.appending(path: "Xattrs.json") }
  private typealias Attributes = [String: [String: Data]]

  public init(cacheRoot: URL, connectionID: UUID) {
    root = cacheRoot.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
      .appending(path: "Overlay", directoryHint: .isDirectory)
  }

  public static func handles(_ path: RemotePath) -> Bool {
    path.value.split(separator: "/").contains { reservedNames.contains(String($0)) }
  }

  public func stat(_ path: RemotePath) throws -> RemoteItem {
    let details = try details(at: file(path))
    return item(path, details: details)
  }

  public func list(_ path: RemotePath) throws -> [RemoteItem] {
    let directory = file(path)
    guard let details = try existingDetails(at: directory) else {
      if Self.handles(path) { throw RemoteError.posix(ENOENT) }
      return []
    }
    guard isDirectory(details) else { throw RemoteError.posix(ENOTDIR) }
    let children = try localOperation {
      try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
    return try children.compactMap { name in
      let child = try path.appending(name)
      guard Self.handles(child) else { return nil }
      return try stat(child)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func createFile(_ path: RemotePath) throws -> RemoteItem {
    try prepareParent(of: path)
    let descriptor = Darwin.open(file(path).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw posixFailure() }
    Darwin.close(descriptor)
    return try stat(path)
  }

  public func makeDirectory(_ path: RemotePath) throws -> RemoteItem {
    try prepareParent(of: path)
    guard Darwin.mkdir(file(path).path, 0o700) == 0 else { throw posixFailure() }
    return try stat(path)
  }

  public func read(_ path: RemotePath, offset: Int64, length: Int) throws -> Data {
    guard offset >= 0, length >= 0, !offset.addingReportingOverflow(Int64(length)).overflow else {
      throw RemoteError.posix(EINVAL)
    }
    let descriptor = try openFile(path, flags: O_RDONLY)
    defer { Darwin.close(descriptor) }
    var data = Data(count: length)
    let count = try data.withUnsafeMutableBytes { bytes in
      let count = Darwin.pread(descriptor, bytes.baseAddress, length, off_t(offset))
      guard count >= 0 else { throw posixFailure() }
      return count
    }
    data.count = count
    return data
  }

  public func write(_ path: RemotePath, offset: Int64, data: Data) throws -> Int {
    guard offset >= 0, !offset.addingReportingOverflow(Int64(data.count)).overflow else {
      throw RemoteError.posix(EINVAL)
    }
    let descriptor = try openFile(path, flags: O_WRONLY)
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < data.count {
        let count = Darwin.pwrite(
          descriptor, bytes.baseAddress!.advanced(by: written), data.count - written,
          off_t(offset + Int64(written)))
        guard count > 0 else { throw count < 0 ? posixFailure() : RemoteError.posix(EIO) }
        written += count
      }
    }
    return data.count
  }

  public func resize(_ path: RemotePath, size: Int64) throws {
    guard size >= 0 else { throw RemoteError.posix(EINVAL) }
    let descriptor = try openFile(path, flags: O_WRONLY)
    defer { Darwin.close(descriptor) }
    guard Darwin.ftruncate(descriptor, off_t(size)) == 0 else { throw posixFailure() }
  }

  public func setModifiedDate(_ path: RemotePath, date: Date) throws {
    _ = try details(at: file(path))
    try localOperation {
      try FileManager.default.setAttributes(
        [.modificationDate: date], ofItemAtPath: file(path).path)
    }
  }

  public func flush(_ path: RemotePath) throws {
    let target = file(path)
    if try existingDetails(at: target) != nil {
      try synchronize(target)
    } else if Self.handles(path) {
      throw RemoteError.posix(ENOENT)
    }
    if try existingDetails(at: attributesFile) != nil { try synchronize(attributesFile) }
    if try existingDetails(at: root) != nil { try synchronizeDirectory(root) }
  }

  public func remove(_ path: RemotePath, recursive: Bool) throws {
    let target = file(path)
    let details = try details(at: target)
    if isDirectory(details) {
      if recursive {
        try removeLocal(target)
      } else {
        guard Darwin.rmdir(target.path) == 0 else { throw posixFailure() }
      }
    } else {
      guard Darwin.unlink(target.path) == 0 else { throw posixFailure() }
    }
    try removeAttributes(path)
  }

  public func move(_ from: RemotePath, to: RemotePath, replacing: Bool = false) throws {
    let source = try stat(from)
    if from == to { return }
    guard !contains(from, to), !contains(to, from) else { throw RemoteError.posix(EINVAL) }
    if let target = try existingDetails(at: file(to)) {
      guard replacing else { throw RemoteError.posix(EEXIST) }
      guard source.isDirectory == isDirectory(target) else {
        throw RemoteError.posix(source.isDirectory ? ENOTDIR : EISDIR)
      }
      if source.isDirectory, !(try list(to)).isEmpty { throw RemoteError.posix(ENOTEMPTY) }
    }
    try prepareParent(of: to)
    guard Darwin.rename(file(from).path, file(to).path) == 0 else { throw posixFailure() }
    try moveAttributes(from, to: to)
  }

  public func getXattr(named name: Data, of path: RemotePath) throws -> Data {
    guard let value = try loadAttributes()[path.value]?[name.base64EncodedString()] else {
      throw RemoteError.posix(ENOATTR)
    }
    return value
  }

  public func setXattr(
    named name: Data, to value: Data?, on path: RemotePath, policy: RemoteXattrPolicy
  ) throws {
    guard !name.isEmpty, !name.contains(0) else { throw RemoteError.posix(EINVAL) }
    var attributes = try loadAttributes()
    var values = attributes[path.value] ?? [:]
    let key = name.base64EncodedString()
    switch policy {
    case .create:
      guard values[key] == nil else { throw RemoteError.posix(EEXIST) }
      values[key] = value ?? Data()
    case .replace:
      guard values[key] != nil else { throw RemoteError.posix(ENOATTR) }
      values[key] = value ?? Data()
    case .remove:
      guard values.removeValue(forKey: key) != nil else { throw RemoteError.posix(ENOATTR) }
    case .set:
      values[key] = value ?? Data()
    }
    attributes[path.value] = values.isEmpty ? nil : values
    try saveAttributes(attributes)
  }

  public func listXattrs(of path: RemotePath) throws -> [Data] {
    try (loadAttributes()[path.value] ?? [:]).keys.map { key in
      guard let name = Data(base64Encoded: key) else { throw RemoteError.posix(EIO) }
      return name
    }.sorted { $0.lexicographicallyPrecedes($1) }
  }

  public func removeMetadata(_ path: RemotePath) throws {
    let target = file(path)
    if try existingDetails(at: target) != nil { try removeLocal(target) }
    try removeAttributes(path)
  }

  public func moveMetadata(_ from: RemotePath, to: RemotePath) throws {
    if from == to { return }
    guard !contains(from, to), !contains(to, from) else { throw RemoteError.posix(EINVAL) }
    let source = file(from)
    let destination = file(to)
    // 远端替换已成功，目标旧属性不能留给新文件。
    if try existingDetails(at: destination) != nil { try removeLocal(destination) }
    if try existingDetails(at: source) != nil {
      try localOperation {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      }
      guard Darwin.rename(source.path, destination.path) == 0 else { throw posixFailure() }
    }
    try moveAttributes(from, to: to)
  }

  private func file(_ path: RemotePath) -> URL {
    path.value.split(separator: "/").reduce(files) { $0.appendingPathComponent(String($1)) }
  }

  private func prepareParent(of path: RemotePath) throws {
    if Self.handles(path.parent) {
      guard try stat(path.parent).isDirectory else { throw RemoteError.posix(ENOTDIR) }
    } else {
      try localOperation {
        try FileManager.default.createDirectory(
          at: file(path.parent), withIntermediateDirectories: true)
      }
    }
  }

  private func openFile(_ path: RemotePath, flags: Int32) throws -> Int32 {
    guard try !stat(path).isDirectory else { throw RemoteError.posix(EISDIR) }
    let descriptor = Darwin.open(file(path).path, flags)
    guard descriptor >= 0 else { throw posixFailure() }
    return descriptor
  }

  private func existingDetails(at url: URL) throws -> Darwin.stat? {
    var details = Darwin.stat()
    guard Darwin.lstat(url.path, &details) == 0 else {
      if errno == ENOENT { return nil }
      throw posixFailure()
    }
    return details
  }

  private func details(at url: URL) throws -> Darwin.stat {
    guard let details = try existingDetails(at: url) else { throw RemoteError.posix(ENOENT) }
    return details
  }

  private func isDirectory(_ details: Darwin.stat) -> Bool {
    details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
  }

  private func item(_ path: RemotePath, details: Darwin.stat) -> RemoteItem {
    let directory = isDirectory(details)
    return RemoteItem(
      path: path, name: path.basename, isDirectory: directory,
      size: directory ? 0 : details.st_size,
      modified: Date(
        timeIntervalSince1970: Double(details.st_mtimespec.tv_sec)
          + Double(details.st_mtimespec.tv_nsec) / 1_000_000_000))
  }

  private func synchronize(_ url: URL) throws {
    if try isDirectory(details(at: url)) {
      let children = try localOperation {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
      }
      for child in children { try synchronize(url.appendingPathComponent(child)) }
      try synchronizeDirectory(url)
    } else {
      try synchronizeDirectory(url)
    }
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw posixFailure() }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw posixFailure() }
  }

  private func loadAttributes() throws -> Attributes {
    guard try existingDetails(at: attributesFile) != nil else { return [:] }
    do {
      return try JSONDecoder().decode(Attributes.self, from: Data(contentsOf: attributesFile))
    } catch {
      throw RemoteError.posix(EIO)
    }
  }

  private func saveAttributes(_ attributes: Attributes) throws {
    try localOperation {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(attributes).write(to: attributesFile, options: .atomic)
    }
  }

  private func removeAttributes(_ path: RemotePath) throws {
    let original = try loadAttributes()
    let remaining = original.filter { !contains(path, $0.key) }
    if remaining != original { try saveAttributes(remaining) }
  }

  private func moveAttributes(_ from: RemotePath, to: RemotePath) throws {
    let original = try loadAttributes()
    var moved = original.filter { !contains(from, $0.key) && !contains(to, $0.key) }
    for (path, attributes) in original where contains(from, path) {
      moved[to.value + path.dropFirst(from.value.count)] = attributes
    }
    if moved != original { try saveAttributes(moved) }
  }

  private func contains(_ parent: RemotePath, _ child: RemotePath) -> Bool {
    contains(parent, child.value)
  }

  private func contains(_ parent: RemotePath, _ child: String) -> Bool {
    parent.value == child || child.hasPrefix(parent.value == "/" ? "/" : parent.value + "/")
  }

  private func removeLocal(_ url: URL) throws {
    try localOperation { try FileManager.default.removeItem(at: url) }
  }

  private func posixFailure() -> RemoteError { .posix(errno) }

  private func localOperation<Value>(_ body: () throws -> Value) throws -> Value {
    do { return try body() } catch {
      let value = error as NSError
      if value.domain == NSPOSIXErrorDomain { throw RemoteError.posix(Int32(value.code)) }
      if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError,
        underlying.domain == NSPOSIXErrorDomain
      {
        throw RemoteError.posix(Int32(underlying.code))
      }
      throw RemoteError.posix(EIO)
    }
  }
}
