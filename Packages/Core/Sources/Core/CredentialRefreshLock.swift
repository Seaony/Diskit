import CryptoKit
import Darwin
import Foundation
import Synchronization

/// 文件锁覆盖读取、刷新与保存；等待时不占住执行线程。
public final class CredentialRefreshLock: Sendable {
  private let descriptor: Mutex<Int32?>

  private init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }

  public static func location(directory: URL, namespace: String, key: String) -> URL {
    let identity = Data((namespace + "\u{0}" + key).utf8)
    let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return directory.appending(path: digest + ".lock")
  }

  public static func acquire(
    at url: URL, onWait: (@Sendable () throws -> Void)? = nil
  ) async throws -> CredentialRefreshLock {
    try await acquire(
      at: url, deadline: .now.advanced(by: .seconds(RemoteTimeout.cloudRequest)), onWait: onWait)
  }

  static func acquire(
    at url: URL, deadline: ContinuousClock.Instant,
    clock: DeadlineClock = .continuous,
    onWait: (@Sendable () throws -> Void)? = nil
  ) async throws -> CredentialRefreshLock {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let lease = CredentialRefreshLock(descriptor: fd)
    do {
      while true {
        try Task.checkCancellation()
        guard clock.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
        let code = errno
        guard code == EWOULDBLOCK || code == EINTR else {
          throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try onWait?()
        try await clock.sleepUntil(min(deadline, clock.now().advanced(by: .milliseconds(10))))
      }
      try Task.checkCancellation()
      guard clock.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
      return lease
    } catch {
      lease.release()
      throw error
    }
  }

  public func release() {
    descriptor.withLock { value in
      guard let fd = value else { return }
      value = nil
      _ = flock(fd, LOCK_UN)
      _ = close(fd)
    }
  }

  deinit { release() }
}
