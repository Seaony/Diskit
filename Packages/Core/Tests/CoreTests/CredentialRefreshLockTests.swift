import CoreTestSupport
import Foundation
import Testing

@testable import Core

func probeLockInChild(_ url: URL) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/python3")
  process.arguments = [
    "-c",
    "import fcntl,sys; f=open(sys.argv[1],'a');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(7)",
    url.path,
  ]
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

@Test func credentialRefreshLockExcludesOtherProcessesAndReleases() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = CredentialRefreshLock.location(directory: directory, namespace: "test", key: "account")
  let lease = try await CredentialRefreshLock.acquire(at: url)
  #expect(try probeLockInChild(url) == 7)
  lease.release()
  lease.release()
  #expect(try probeLockInChild(url) == 0)
  #expect(try Data(contentsOf: url).isEmpty)
}

@Test func credentialRefreshLockWaitCanBeCancelled() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = CredentialRefreshLock.location(directory: directory, namespace: "test", key: "account")
  let lease = try await CredentialRefreshLock.acquire(at: url)
  defer { lease.release() }
  let clock = ManualTestClock()
  let waiting = Task {
    try await CredentialRefreshLock.acquire(
      at: url, deadline: clock.now.advanced(by: .seconds(30)), clock: clock.deadlineClock)
  }
  await clock.waitForSleepRequests(1)
  waiting.cancel()
  await #expect(throws: CancellationError.self) { _ = try await waiting.value }
  #expect(try probeLockInChild(url) == 7)
  #expect(clock.pendingSleepCount == 0)
}

@Test func credentialRefreshLockRejectsSymlink() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let target = directory.appending(path: "target")
  try Data("unchanged".utf8).write(to: target)
  let link = directory.appending(path: "link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  await #expect(throws: POSIXError.self) { _ = try await CredentialRefreshLock.acquire(at: link) }
  #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
}

@Test func credentialRefreshLockIdentityMatchesStorageScope() {
  let first = MemorySecretStore()
  let second = MemorySecretStore()
  #expect(first.refreshLockLocation(for: "account") != second.refreshLockLocation(for: "account"))
  #expect(
    first.refreshLockLocation(for: "account")
      == RecoverableSecretStore(base: first).refreshLockLocation(for: "account"))
  let login = LoginKeychainStore(service: "test.service")
  #expect(
    login.refreshLockLocation(for: "account")
      == LoginKeychainStore(service: "test.service").refreshLockLocation(for: "account"))
  #expect(login.refreshLockLocation(for: "account") != login.refreshLockLocation(for: "other"))
  #expect(
    login.refreshLockLocation(for: "account")
      != LoginKeychainStore(service: "other.service").refreshLockLocation(for: "account"))
}

@Test func credentialRefreshWaitStopsAtDeadline() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "account.lock")
  let owner = try await CredentialRefreshLock.acquire(at: url)
  defer { owner.release() }
  let clock = ManualTestClock()
  let waitingTask = Task {
    try await CredentialRefreshLock.acquire(
      at: url, deadline: clock.now.advanced(by: .seconds(30)), clock: clock.deadlineClock)
  }
  defer { waitingTask.cancel() }
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(30))
  do {
    let waiting = try await waitingTask.value
    waiting.release()
    Issue.record("等待超过截止时间仍获得了刷新锁")
  } catch let error as POSIXError {
    #expect(error.code == .ETIMEDOUT)
    #expect(try probeLockInChild(url) == 7)
  }
}

@Test func expiredRefreshDeadlineCannotAcquireFreeLock() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "account.lock")
  let clock = ManualTestClock()
  do {
    let lease = try await CredentialRefreshLock.acquire(
      at: url, deadline: clock.now.advanced(by: .seconds(-1)), clock: clock.deadlineClock)
    lease.release()
    Issue.record("已过期的请求不应取得刷新锁")
  } catch let error as POSIXError {
    #expect(error.code == .ETIMEDOUT)
  }
}

@Test func refreshLockReleasedBeforeDeadlineCanBeReacquired() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "account.lock")
  let owner = try await CredentialRefreshLock.acquire(at: url)
  defer { owner.release() }
  let clock = ManualTestClock()
  let waiting = Task {
    try await CredentialRefreshLock.acquire(
      at: url, deadline: clock.now.advanced(by: .seconds(30)), clock: clock.deadlineClock)
  }
  defer { waiting.cancel() }
  await clock.waitForSleepRequests(1)
  owner.release()
  clock.advance(by: .milliseconds(10))
  let next = try await waiting.value
  defer { next.release() }
  #expect(try probeLockInChild(url) == 7)
}
