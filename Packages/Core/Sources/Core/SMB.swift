import AppKit
import CoreNative
import Darwin
import Foundation
import NetFS
import OSLog

public struct MountedShare: Equatable, Sendable {
  public var url: URL
  public var availableBytes: Int64
  public init(url: URL, availableBytes: Int64 = 0) {
    self.url = url
    self.availableBytes = availableBytes
  }
}

@MainActor public protocol SMBServing: AnyObject {
  func shares(host: String, user: String, password: String) async throws -> [String]
  func test(_ connection: Connection, password: String) async throws
  func mount(_ connection: Connection, password: String) async throws -> URL
  func unmount(_ url: URL) async throws
  func mounted(_ connection: Connection) -> MountedShare?
}

public enum SMBAddress {
  public static func url(host: String, user: String? = nil, share: String? = nil) throws -> URL {
    guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else {
      throw ConnectionError.invalidFields
    }
    var parts = URLComponents()
    parts.scheme = "smb"
    parts.host = host
    parts.user = user
    if let share { parts.path = "/" + share }
    guard let url = parts.url else { throw ConnectionError.invalidFields }
    return url
  }
  public static func parseShares(_ output: String, exitStatus: Int32) throws -> [String] {
    guard exitStatus == 0 else {
      let lower = output.lowercased()
      if lower.contains("authentication") || lower.contains("logon failure")
        || lower.contains("permission denied") || lower.contains("password incorrect")
      {
        throw ConnectionError.authentication
      }
      if lower.contains("timed out") { throw ConnectionError.timeout }
      throw ConnectionError.system(exitStatus)
    }
    // smbutil 的共享名可以含空格，从类型列向前取完整名称。
    let regex = try NSRegularExpression(
      pattern: #"^(.+?)\s{2,}(Disk|Printer|Pipe|Comm|Unknown)\s*(.*)$"#)
    return output.components(separatedBy: .newlines).compactMap { line in
      let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let nameRange = Range(match.range(at: 1), in: text),
        let typeRange = Range(match.range(at: 2), in: text), text[typeRange] == "Disk"
      else { return nil }
      return String(text[nameRange]).trimmingCharacters(in: .whitespaces)
    }
  }
}

public enum SystemMountAddress {
  public static func url(for connection: Connection) throws -> URL {
    switch connection.kind {
    case .smb:
      return try SMBAddress.url(
        host: connection.params["host"] ?? "",
        user: connection.params["username"],
        share: connection.params["share"])
    case .webdav, .webdavHTTPS:
      return try url(
        scheme: connection.kind == .webdavHTTPS ? "https" : "http",
        address: connection.params["url"] ?? "",
        path: nil)
    case .nfs:
      return try url(
        scheme: "nfs", address: connection.params["host"] ?? "",
        path: connection.params["path"])
    default:
      throw ConnectionError.invalidFields
    }
  }

  public static func matches(connection: Connection, source: String, type: String) -> Bool {
    guard let expectedType = fileSystemType(for: connection.kind), type == expectedType,
      let expected = try? url(for: connection)
    else { return false }
    if connection.kind == .nfs, !source.lowercased().hasPrefix("nfs:") {
      let parts = source.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return false }
      return parts[0].lowercased() == expected.host?.lowercased()
        && normalizedPath(parts[1].hasPrefix("/") ? String(parts[1]) : "/" + parts[1])
          == normalizedPath(expected.path)
    }
    let normalizedSource =
      source.hasPrefix(expected.scheme! + ":")
      ? source : expected.scheme! + ":" + source
    guard let actual = URLComponents(string: normalizedSource) else { return false }
    return actual.host?.lowercased() == expected.host?.lowercased()
      && normalizedPath(actual.path) == normalizedPath(expected.path)
  }

  private static func url(scheme: String, address: String, path: String?) throws -> URL {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ConnectionError.invalidFields }
    if let components = URLComponents(string: value),
      let valueScheme = components.scheme?.lowercased()
    {
      guard valueScheme == scheme, components.host != nil, components.user == nil else {
        throw ConnectionError.invalidFields
      }
      return components.url!
    }
    guard !value.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else {
      throw ConnectionError.invalidFields
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = value
    components.path = path.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? ""
    guard let url = components.url else { throw ConnectionError.invalidFields }
    return url
  }

  private static func fileSystemType(for kind: ConnectionKind) -> String? {
    switch kind {
    case .smb: "smbfs"
    case .webdav, .webdavHTTPS: "webdav"
    case .nfs: "nfs"
    default: nil
    }
  }

  private static func normalizedPath(_ path: String) -> String {
    let value = path.isEmpty ? "/" : path
    return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
  }
}

@MainActor public final class SystemSMBService: SMBServing {
  private let location: any StorageLocation
  public init(location: any StorageLocation = LocalStorageLocation()) { self.location = location }
  public func test(_ connection: Connection, password: String) async throws {
    let directory = location.connectionTestDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 只删除空挂载点，推出失败时绝不能递归删除远端内容。
    defer { _ = rmdir(directory.path) }
    let url = try SystemMountAddress.url(for: connection)
    let mounted = try await MountRequest().run(
      url: url, user: connection.params["username"] ?? "", password: password,
      guest: connection.params["guest"] == "true", mountPoint: directory
    )
    guard mounted.standardizedFileURL == directory.standardizedFileURL else {
      throw ConnectionError.system(EIO)
    }
    try await unmount(mounted)
  }
  public func shares(host: String, user: String, password: String) async throws -> [String] {
    let url = try SMBAddress.url(host: host, user: user)
    guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
      throw ConnectionError.authentication
    }
    let server = String(url.absoluteString.dropFirst(4))
    return try await Task.detached {
      var output = [CChar](repeating: 0, count: 1_048_576)
      var status: Int32 = 0
      let result = kayoi_smb_shares(server, password, &output, output.count, &status)
      guard result == 0 else { throw ConnectionError.status(result) }
      return try SMBAddress.parseShares(
        String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        exitStatus: status)
    }.value
  }
  public func mount(_ connection: Connection, password: String) async throws -> URL {
    let url = try SystemMountAddress.url(for: connection)
    return try await MountRequest().run(
      url: url, user: connection.params["username"] ?? "", password: password,
      guest: connection.params["guest"] == "true")
  }
  public func unmount(_ url: URL) async throws {
    try await UnmountRequest().run(url)
  }

  public func mounted(_ connection: Connection) -> MountedShare? {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&table, MNT_NOWAIT)
    guard let table else { return nil }
    for index in 0..<Int(count) {
      var entry = table[index]
      let type = withUnsafePointer(to: &entry.f_fstypename) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      let source = withUnsafePointer(to: &entry.f_mntfromname) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      guard SystemMountAddress.matches(connection: connection, source: source, type: type) else {
        continue
      }
      let path = withUnsafePointer(to: &entry.f_mntonname) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      return MountedShare(
        url: URL(fileURLWithPath: path),
        availableBytes: Int64(entry.f_bavail) * Int64(entry.f_bsize))
    }
    return nil
  }
}

@MainActor final class MountRequest {
  private static let logger = Logger(subsystem: "com.seaony.Kayoi", category: "MountCleanup")
  private var abandoned = false
  private var request: AsyncRequestID?
  private var continuation: CheckedContinuation<URL, Error>?
  private var timer: Task<Void, Never>?
  private let unmountLate: @MainActor (URL) async throws -> Void
  private let cleanupFailed: @MainActor (URL, Error) -> Void
  init(
    unmountLate: @escaping @MainActor (URL) async throws -> Void = {
      try await UnmountRequest().run($0)
    },
    cleanupFailed: @escaping @MainActor (URL, Error) -> Void = { url, error in
      MountRequest.logger.error(
        "推出迟到挂载失败：\(url.path, privacy: .private)，\(error.localizedDescription, privacy: .private)")
    }
  ) {
    self.unmountLate = unmountLate
    self.cleanupFailed = cleanupFailed
  }
  func waitForResult(_ start: () -> Void) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      start()
    }
  }
  func received(status: Int32, paths: [String]) async {
    if abandoned, status == 0 {
      for path in paths {
        let url = URL(fileURLWithPath: path)
        do { try await unmountLate(url) } catch { cleanupFailed(url, error) }
      }
      return
    }
    if status == 0, let path = paths.first {
      finish(.success(URL(fileURLWithPath: path)))
    } else {
      finish(.failure(ConnectionError.status(status == 0 ? EIO : status)))
    }
  }
  func run(
    url: URL, user: String, password: String, guest: Bool = false, mountPoint: URL? = nil
  ) async throws -> URL {
    try await withTaskCancellationHandler {
      try await waitForResult {
        let options = NSMutableDictionary(dictionary: [
          kNAUIOptionKey as String: kNAUIOptionNoUI, kNetFSForceNewSessionKey as String: true,
          kNetFSUseAuthenticationInfoKey as String: false, kNetFSAllowLoopbackKey as String: true,
        ])
        if guest { options[kNetFSUseGuestKey as String] = true }
        let mountOptions: NSMutableDictionary? = mountPoint.map { _ in
          NSMutableDictionary(dictionary: [
            kNetFSMountAtMountDirKey as String: true,
            kNetFSMountFlagsKey as String: MNT_DONTBROWSE,
          ])
        }
        let status = NetFSMountURLAsync(
          url as CFURL, mountPoint.map { $0 as CFURL }, user as CFString, password as CFString,
          options, mountOptions, &request, .main
        ) { status, _, points in
          let paths = (points as? [String]) ?? []
          Task { @MainActor in
            await self.received(status: status, paths: paths)
          }
        }
        if status != 0 {
          finish(.failure(ConnectionError.status(status)))
          return
        }
        timer = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          if let request = self.request { NetFSMountURLCancel(request) }
          self.finish(.failure(ConnectionError.timeout))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  private func cancel() {
    if let request { NetFSMountURLCancel(request) }
    finish(.failure(CancellationError()))
  }
  func finish(_ result: Result<URL, Error>) {
    guard let continuation else { return }
    if case .failure = result { abandoned = true }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    request = nil
    continuation.resume(with: result)
  }
}

@MainActor private final class UnmountRequest {
  private var continuation: CheckedContinuation<Void, Error>?
  private var timer: Task<Void, Never>?
  func run(_ url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      Task.detached {
        let result = Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        await self.finish(result)
      }
      timer = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        self.finish(.failure(ConnectionError.timeout))
      }
    }
  }
  private func finish(_ result: Result<Void, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}
