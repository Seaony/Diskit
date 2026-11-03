import AppKit
import CoreNative
import Darwin
import Foundation
import NetFS

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

@MainActor public final class SystemSMBService: SMBServing {
  private let location: any StorageLocation
  public init(location: any StorageLocation = LocalStorageLocation()) { self.location = location }
  public func test(_ connection: Connection, password: String) async throws {
    let directory = location.cacheDirectory.appending(path: "ConnectionTests/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 只删除空挂载点，推出失败时绝不能递归删除远端内容。
    defer { _ = rmdir(directory.path) }
    let url = try SMBAddress.url(
      host: connection.params["host"] ?? "", share: connection.params["share"] ?? "")
    let mounted = try await MountRequest().run(
      url: url, user: connection.params["username"] ?? "", password: password, mountPoint: directory
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
    let url = try SMBAddress.url(
      host: connection.params["host"] ?? "", share: connection.params["share"] ?? "")
    return try await MountRequest().run(
      url: url, user: connection.params["username"] ?? "", password: password)
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
      guard type == "smbfs" else { continue }
      let source = withUnsafePointer(to: &entry.f_mntfromname) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      guard let parts = URLComponents(string: "smb:" + source),
        parts.host?.lowercased() == connection.params["host"]?.lowercased(),
        parts.path == "/" + (connection.params["share"] ?? "")
      else { continue }
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

@MainActor private final class MountRequest {
  private var request: AsyncRequestID?
  private var continuation: CheckedContinuation<URL, Error>?
  private var timer: Task<Void, Never>?
  func run(url: URL, user: String, password: String, mountPoint: URL? = nil) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let options = NSMutableDictionary(dictionary: [
        kNAUIOptionKey as String: kNAUIOptionNoUI, kNetFSForceNewSessionKey as String: true,
        kNetFSUseAuthenticationInfoKey as String: false,
      ])
      let mountOptions: NSMutableDictionary? = mountPoint.map { _ in
        NSMutableDictionary(dictionary: [
          kNetFSMountAtMountDirKey as String: true, kNetFSMountFlagsKey as String: MNT_DONTBROWSE,
        ])
      }
      let status = NetFSMountURLAsync(
        url as CFURL, mountPoint.map { $0 as CFURL }, user as CFString, password as CFString,
        options, mountOptions, &request, .main
      ) { status, _, points in
        let paths = (points as? [String]) ?? []
        Task { @MainActor in
          if status == 0, let path = paths.first {
            self.finish(.success(URL(fileURLWithPath: path)))
          } else {
            self.finish(.failure(ConnectionError.status(status == 0 ? EIO : status)))
          }
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
  }
  private func finish(_ result: Result<URL, Error>) {
    guard let continuation else { return }
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
