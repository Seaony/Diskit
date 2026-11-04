import AppKit
import CoreNative
import Darwin
import Foundation
import NetFS

@MainActor final class MountRequest {
  private var abandoned = false
  private let native: any MountCalling
  private let clock: DeadlineClock
  private var continuation: CheckedContinuation<URL, Error>?
  private var timer: Task<Void, Never>?
  private let unmountLate: @MainActor (URL) async throws -> Void
  private let cleanupFailed: @MainActor (URL, Error) -> Void
  init(
    native: any MountCalling = NativeMountCall(), clock: DeadlineClock = .continuous,
    unmountLate: @escaping @MainActor (URL) async throws -> Void = {
      try await UnmountRequest().run($0)
    },
    cleanupFailed: @escaping @MainActor (URL, Error) -> Void = { _, error in
      PackageDiagnostics.failure(error, category: .core, operation: .unmount)
    }
  ) {
    self.native = native
    self.clock = clock
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
        let status = native.start(
          url: url, mountPoint: mountPoint, user: user, password: password,
          options: options, mountOptions: mountOptions
        ) { status, paths in
          Task { @MainActor in await self.received(status: status, paths: paths) }
        }
        if status != 0 {
          finish(.failure(ConnectionError.status(status)))
          return
        }
        timer = Task { @MainActor in
          do {
            try await clock.sleepUntil(
              clock.now().advanced(by: .seconds(RemoteTimeout.deviceRequest)))
          } catch { return }
          self.native.cancel()
          self.finish(.failure(ConnectionError.timeout))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  private func cancel() {
    native.cancel()
    finish(.failure(CancellationError()))
  }
  func finish(_ result: Result<URL, Error>) {
    guard let continuation else { return }
    if case .failure(let error) = result {
      PackageDiagnostics.failure(error, category: .core, operation: .mount)
      abandoned = true
    }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    native.finished()

    continuation.resume(with: result)
  }
}
