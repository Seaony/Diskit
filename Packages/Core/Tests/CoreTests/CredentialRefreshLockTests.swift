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
  let waiting = Task { try await CredentialRefreshLock.acquire(at: url) }
  waiting.cancel()
  await #expect(throws: CancellationError.self) { _ = try await waiting.value }
  #expect(try probeLockInChild(url) == 7)
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
