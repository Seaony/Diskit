import Core
import CoreTestSupport
import Foundation
import Testing

#if canImport(MountDraft)
@testable import MountDraft
#endif

@MainActor private final class FileSystemMountFixture {
  let location = LocalStorageLocation(home: FileManager.default.temporaryDirectory.appending(path: "KayoiMountTests-" + UUID().uuidString))
  let started = TestEvent()
  let ejected = TestEvent()
  var shared = true
  var enabled: Bool? = true
  var useClient = true
  var completeMount = true
  var completeUnmount = true
  var extensionQueries = 0
  var calls: [String] = []
  var points: [URL] = []
  var unmounted: [URL] = []
  var unmountFailure: Error?
  var pendingMount: FileSystemCompletion<URL>?
  var pendingUnmount: FileSystemCompletion<Void>?
  var entries: [FileSystemMountService.MountEntry] = []
  var saved: [Connection] = []

  func operations() -> FileSystemMountService.Operations {
    var operations = FileSystemMountService.Operations()
    operations.sharedStorageAvailable = { [self] in shared }
    operations.usesClient = { [self] in useClient }
    operations.enabled = { [self] completion in
      extensionQueries += 1
      completion(.success(enabled))
    }
    operations.mountClient = { [self] _, completion in
      calls.append("client")
      pendingMount = completion
      started.signal()
      if completeMount { completion(.success(URL(filePath: "/Volumes/Fixture"))) }
    }
    operations.mountCommand = { [self] _, point, completion in
      calls.append("command")
      points.append(point)
      pendingMount = completion
      started.signal()
      if completeMount { completion(.success(point)) }
    }
    operations.unmount = { [self] url, completion in
      unmounted.append(url)
      pendingUnmount = completion
      ejected.signal()
      guard completeUnmount else { return }
      if let unmountFailure { completion(.failure(unmountFailure)) }
      else { completion(.success(())) }
    }
    operations.entries = { [self] in entries }
    operations.capacity = { _ in nil }
    operations.savedConnections = { [self] in saved }
    operations.openSettings = { true }
    return operations
  }

  func removeFiles() { try? FileManager.default.removeItem(at: location.dataDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
}

private func mountConnection(_ kind: ConnectionKind = .androidUSB, id: UUID = UUID()) -> Connection {
  Connection(id: id, kind: kind, name: "与挂载目录不同的名称")
}

private func mountEntry(_ connection: Connection, path: String = "/Volumes/Fixture", filesystemID: Data = Data([1]), available: Int64? = nil) throws -> FileSystemMountService.MountEntry {
  FileSystemMountService.MountEntry(type: "kayoi", source: try FileSystemAddress.url(for: connection).absoluteString, path: URL(filePath: path), filesystemID: filesystemID, availableBytes: available)
}

@MainActor @Test func mountSelectsSystemVersionAndDoesNotHideLocalFiles() async throws {
  for client in [false, true] {
    let fixture = FileSystemMountFixture()
    defer { fixture.removeFiles() }
    fixture.useClient = client
    let connection = mountConnection()
    let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
    let result = try await service.mount(connection, password: "")
    #expect(fixture.calls == [client ? "client" : "command"])
    if !client {
      #expect(result.lastPathComponent == connection.id.uuidString.lowercased())
      #expect(result.deletingLastPathComponent() == fixture.location.dataDirectory.appending(path: "Mounts", directoryHint: .isDirectory))
      try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
      let original = result.appending(path: "keep.txt")
      try Data("保留".utf8).write(to: original)
      await #expect(throws: POSIXError.self) { try await service.mount(connection, password: "") }
      #expect(try Data(contentsOf: original) == Data("保留".utf8))
      #expect(fixture.calls == ["command"])
    }
  }
}

@MainActor @Test func mountChecksDisabledAndUnavailableBeforeStartingFSKit() async throws {
  for (shared, enabled, expected) in [(false, true, FileSystemExtensionState.unavailable), (true, false, .disabled), (true, nil, .unavailable)] as [(Bool, Bool?, FileSystemExtensionState)] {
    let fixture = FileSystemMountFixture()
    fixture.shared = shared
    fixture.enabled = enabled
    let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
    #expect(await service.extensionStatus() == expected)
    await #expect(throws: FileSystemMountError.self) { try await service.mount(mountConnection(), password: "") }
    #expect(fixture.calls.isEmpty)
    if !shared { #expect(fixture.extensionQueries == 0) }
  }
}

@MainActor @Test func mountedIdentityUsesURLAndIDInsteadOfVolumeName() async throws {
  let fixture = FileSystemMountFixture()
  let first = mountConnection()
  let cloud = mountConnection(.aliyunDrive)
  var wrongKind = try mountEntry(first, path: "/Volumes/Wrong")
  wrongKind = FileSystemMountService.MountEntry(type: "smbfs", source: wrongKind.source, path: wrongKind.path, filesystemID: wrongKind.filesystemID)
  fixture.entries = [wrongKind, try mountEntry(mountConnection(), path: "/Volumes/SameName"), try mountEntry(first, path: "/Volumes/Unrelated"), try mountEntry(cloud, path: "/Volumes/Cloud")]
  let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
  #expect(service.mounted(first)?.url.path == "/Volumes/Unrelated")
  #expect(service.mounted(first)?.availableBytes == nil)
  #expect(service.mountedVolumes().count == 3)
  #expect(service.isFileSystemVolume(URL(filePath: "/Volumes/Cloud")))
  #expect(!service.isFileSystemVolume(URL(filePath: "/Volumes/Wrong")))
  #expect(try await service.mount(first, password: "").path == "/Volumes/Unrelated")
  #expect(fixture.calls.isEmpty)
}

@MainActor @Test func cancelledAndTimedOutMountsEjectLateSuccess() async throws {
  for cancel in [false, true] {
    let fixture = FileSystemMountFixture()
    fixture.completeMount = false
    let clock = ManualTestClock()
    var operations = fixture.operations()
    operations.sleep = { duration in
      if duration == .seconds(90) { try await clock.sleep(for: duration) }
      else { try await Task.sleep(for: duration) }
    }
    let service = FileSystemMountService(location: fixture.location, operations: operations)
    let task = Task { try await service.mount(mountConnection(), password: "") }
    try await fixture.started.wait()
    await clock.waitForSleepRequests(1)
    if cancel { task.cancel() } else { clock.advance(by: .seconds(90)) }
    do {
      _ = try await task.value
      Issue.record("取消或超时不应返回挂载成功")
    } catch {
      if cancel { #expect(error is CancellationError) }
      else { #expect(error as? ConnectionError == .timeout) }
    }
    let late = URL(filePath: "/Volumes/Late")
    fixture.pendingMount?(.success(late))
    try await fixture.ejected.wait()
    #expect(fixture.unmounted == [late])
  }
}

@MainActor @Test func unmountAllWaitsForCancelledMountAndItsNativeCleanup() async throws {
  let fixture = FileSystemMountFixture()
  fixture.completeMount = false
  fixture.completeUnmount = false
  let clock = ManualTestClock()
  var operations = fixture.operations()
  operations.sleep = { duration in
    if duration == .seconds(90) { try await clock.sleep(for: duration) }
    else { try await Task.sleep(for: duration) }
  }
  let service = FileSystemMountService(location: fixture.location, operations: operations)
  let mount = Task { try await service.mount(mountConnection(), password: "") }
  try await fixture.started.wait()
  await clock.waitForSleepRequests(1)
  #expect(service.hasActiveVolumesOrMounts)
  mount.cancel()
  await #expect(throws: CancellationError.self) { try await mount.value }
  let finished = TestEvent()
  let ejectAll = Task {
    try await service.unmountAll()
    finished.signal()
  }
  await clock.waitForSleepRequests(2)
  #expect(!finished.isSignaled)
  fixture.pendingMount?(.success(URL(filePath: "/Volumes/Late")))
  try await fixture.ejected.wait()
  #expect(!finished.isSignaled)
  fixture.pendingUnmount?(.success(()))
  try await ejectAll.value
  #expect(finished.isSignaled)
  #expect(!service.hasActiveVolumesOrMounts)
  #expect(fixture.unmounted.map(\.path) == ["/Volumes/Late"])
}

@MainActor @Test func cacheMaintenanceStopsMountsUntilEndAndReopensGateAfterFailure() async throws {
  let fixture = FileSystemMountFixture()
  let connection = mountConnection()
  fixture.entries = [try mountEntry(connection)]
  let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
  #expect(service.hasActiveVolumesOrMounts)
  try await service.beginCacheMaintenance()
  #expect(fixture.unmounted.map(\.path) == ["/Volumes/Fixture"])
  fixture.entries = []
  #expect(!service.hasActiveVolumesOrMounts)
  await #expect(throws: ConnectionError.busy) { try await service.mount(connection, password: "") }
  #expect(fixture.calls.isEmpty)
  service.endCacheMaintenance()
  _ = try await service.mount(connection, password: "")
  fixture.entries = [try mountEntry(connection)]
  fixture.unmountFailure = POSIXError(.EBUSY)
  await #expect(throws: POSIXError.self) { try await service.beginCacheMaintenance() }
  fixture.entries = []
  _ = try await service.mount(connection, password: "")
  #expect(fixture.calls == ["client", "client"])
}

@MainActor @Test func cacheMaintenanceAlsoStopsMountsWaitingForExtensionStatus() async throws {
  let fixture = FileSystemMountFixture()
  let checking = TestEvent()
  var pendingStatus: FileSystemCompletion<Bool?>?
  var operations = fixture.operations()
  operations.enabled = { completion in
    pendingStatus = completion
    checking.signal()
  }
  let service = FileSystemMountService(location: fixture.location, operations: operations)
  let mount = Task { try await service.mount(mountConnection(), password: "") }
  try await checking.wait()
  try await service.beginCacheMaintenance()
  pendingStatus?(.success(true))
  await #expect(throws: ConnectionError.busy) { try await mount.value }
  #expect(fixture.calls.isEmpty)
  service.endCacheMaintenance()
}

@MainActor @Test func unmountRunsDespiteCallerCancellationAndReturnsErrors() async throws {
  let fixture = FileSystemMountFixture()
  let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
  let task = Task { try await service.unmount(URL(filePath: "/Volumes/Cancelled")) }
  task.cancel()
  try await task.value
  #expect(fixture.unmounted.map(\.lastPathComponent) == ["Cancelled"])
  fixture.unmountFailure = POSIXError(.EBUSY)
  await #expect(throws: POSIXError.self) { try await service.unmount(URL(filePath: "/Volumes/Busy")) }
  fixture.entries = [try mountEntry(mountConnection()), try mountEntry(mountConnection(.quark), path: "/Volumes/Other")]
  await #expect(throws: POSIXError.self) { try await service.unmountAll() }
  #expect(fixture.unmounted.suffix(2).map(\.lastPathComponent) == ["Fixture", "Other"])
}

@MainActor @Test func fileSystemConnectionTestRequiresSavedConfigurationAndKeepsExistingMount() async throws {
  let fixture = FileSystemMountFixture()
  let connection = mountConnection()
  let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
  await #expect(throws: FileSystemMountError.self) { try await service.test(connection, password: "") }
  #expect(fixture.calls.isEmpty)
  fixture.saved = [connection]
  try await service.test(connection, password: "")
  #expect(fixture.calls == ["client"])
  #expect(fixture.unmounted.map(\.path) == ["/Volumes/Fixture"])
  fixture.entries = [try mountEntry(connection)]
  try await service.test(connection, password: "")
  #expect(fixture.calls == ["client"])
  #expect(fixture.unmounted.count == 1)
}

@MainActor @Test func mountedCapacityReadsOffMainThreadAndKeepsUnknownCapacityUnknown() async throws {
  let fixture = FileSystemMountFixture()
  let connection = mountConnection()
  let entry = try mountEntry(connection, available: 4096)
  fixture.entries = [try mountEntry(connection)]
  var operations = fixture.operations()
  operations.capacity = { _ in
    #expect(!Thread.isMainThread)
    return entry
  }
  let service = FileSystemMountService(location: fixture.location, operations: operations)
  #expect(await service.refreshMounted(connection)?.availableBytes == 4096)
  #expect(NativeFileSystemMountTable.availableBytes(totalBlocks: 0, availableBlocks: 0, blockSize: 4096) == nil)
  #expect(NativeFileSystemMountTable.availableBytes(totalBlocks: 1, availableBlocks: 0, blockSize: 4096) == 0)
  #expect(NativeFileSystemMountTable.availableBytes(totalBlocks: 1, availableBlocks: UInt64.max, blockSize: 4096) == nil)
}

private final class FileSystemCapacityGate: Sendable {
  let started = TestEvent()
  private let semaphore = DispatchSemaphore(value: 0)
  func read() {
    #expect(!Thread.isMainThread)
    started.signal()
    semaphore.wait()
  }
  func release() { semaphore.signal() }
}

@MainActor @Test func blockedCapacityReadReturnsAtDeadline() async throws {
  let fixture = FileSystemMountFixture()
  let connection = mountConnection()
  fixture.entries = [try mountEntry(connection)]
  let gate = FileSystemCapacityGate()
  defer { gate.release() }
  let clock = ManualTestClock()
  var operations = fixture.operations()
  operations.sleep = { try await clock.sleep(for: $0) }
  operations.capacity = { _ in gate.read(); return nil }
  let service = FileSystemMountService(location: fixture.location, operations: operations)
  let task = Task { await service.refreshMounted(connection) }
  try await gate.started.wait()
  await clock.waitForSleepRequests(1)
  clock.advance(by: .seconds(RemoteTimeout.deviceRequest))
  #expect(await task.value?.availableBytes == nil)
}

@MainActor private final class SystemRouteFixture: SMBServing {
  var calls: [String] = []
  func shares(host: String, user: String, password: String) async throws -> [String] { calls.append("shares"); return ["share"] }
  func test(_ connection: Connection, password: String) async throws { calls.append("test") }
  func mount(_ connection: Connection, password: String) async throws -> URL { calls.append(connection.kind.rawValue); return URL(filePath: "/Volumes/System") }
  func unmount(_ url: URL) async throws { calls.append("unmount") }
  func mounted(_ connection: Connection) -> MountedShare? { nil }
}

@MainActor @Test func routingKeepsSystemSharesAndRoutesEjectByActualFileSystem() async throws {
  let fixture = FileSystemMountFixture()
  fixture.entries = [try mountEntry(mountConnection())]
  let service = FileSystemMountService(location: fixture.location, operations: fixture.operations())
  let system = SystemRouteFixture()
  let routing = RoutingMountService(system: system, fileSystem: service)
  for kind in [ConnectionKind.smb, .webdav, .webdavHTTPS, .nfs] { _ = try await routing.mount(mountConnection(kind), password: "") }
  #expect(try await routing.shares(host: "fixture", user: "", password: "") == ["share"])
  _ = try await routing.mount(mountConnection(.quark), password: "")
  await #expect(throws: RemoteError.self) { try await routing.mount(mountConnection(.ricohGR), password: "") }
  try await routing.unmount(URL(filePath: "/Volumes/Fixture"))
  try await routing.unmount(URL(filePath: "/Volumes/System"))
  #expect(system.calls == ["smb", "webdav", "webdavHTTPS", "nfs", "shares", "unmount"])
  #expect(fixture.unmounted.map(\.path) == ["/Volumes/Fixture"])
}
