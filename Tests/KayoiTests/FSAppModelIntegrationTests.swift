import AppKit
import Core
import Foundation
import Synchronization
import Testing
import UserNotifications

@MainActor private final class FSAppModelHarness {
  let home = FileManager.default.temporaryDirectory.appending(path: "FSAppModel-" + UUID().uuidString)
  lazy var location = LocalStorageLocation(home: home)
  let preferences = UserDefaults(suiteName: "FSAppModel." + UUID().uuidString)!
  let secrets = MemorySecretStore()
  var enabled: Bool? = true
  var queries = 0
  var mounts = 0
  var unmounts = 0
  var settings = 0
  var unmountFailure: Error?
  var saved: [Connection] = []
  var entries: [FileSystemMountService.MountEntry] = []
  var alerts: [(title: String, message: String, buttons: [String])] = []
  var notifications: [UNNotificationRequest] = []

  func clean() { try? FileManager.default.removeItem(at: home) }

  func entry(_ connection: Connection) throws -> FileSystemMountService.MountEntry {
    FileSystemMountService.MountEntry(
      type: "kayoi", source: try FileSystemAddress.url(for: connection).absoluteString,
      path: URL(filePath: "/Volumes/Fixture-" + connection.id.uuidString),
      filesystemID: Data(connection.id.uuidString.utf8), availableBytes: 4096)
  }

  func model(connections: [Connection]) throws -> AppModel {
    saved = connections
    try ConnectionRepository(location: location).save(connections)
    var operations = FileSystemMountService.Operations()
    operations.sharedStorageAvailable = { true }
    operations.usesClient = { true }
    operations.enabled = { [self] completion in
      queries += 1
      completion(.success(enabled))
    }
    operations.mountClient = { [self] address, completion in
      mounts += 1
      let connection = try FileSystemAddress.connection(for: address, in: saved)
      let mounted = try entry(connection)
      entries.append(mounted)
      completion(.success(mounted.path))
    }
    operations.mountCommand = { _, _, completion in
      Issue.record("测试不能调用真实挂载命令")
      completion(.failure(RemoteError.unsupported))
    }
    operations.unmount = { [self] url, completion in
      unmounts += 1
      if let unmountFailure { completion(.failure(unmountFailure)) }
      else {
        entries.removeAll { $0.path == url }
        completion(.success(()))
      }
    }
    operations.entries = { [self] in entries }
    operations.capacity = { _ in nil }
    operations.savedConnections = { [self] in saved }
    operations.openSettings = { [self] in settings += 1; return true }
    let fileSystem = FileSystemMountService(location: location, operations: operations)
    let system = AppSystemServices(
      open: { _ in Issue.record("测试不能打开真实桌面位置") }, copy: { _ in },
      alert: { [self] title, message, buttons, completion in
        alerts.append((title, message, buttons))
        completion(.alertFirstButtonReturn)
      }, requestNotifications: {}, notificationStatus: { .authorized },
      notify: { [self] in notifications.append($0) })
    let dependencies = AppModelDependencies(
      location: location, secrets: secrets, preferences: preferences,
      smb: RoutingMountService(system: DemoMountService(delay: {}), fileSystem: fileSystem),
      httpTransport: EditorLoginHTTP { _ in throw RemoteError.unsupported },
      updates: UpdateController(isDemo: true), system: system, fileSystem: fileSystem)
    let model = AppModel(options: RuntimeOptions(environment: [:]), dependencies: dependencies)
    model.configureConnections()
    return model
  }
}

private func fsAppModelConnection(_ kind: ConnectionKind = .quark) -> Connection {
  Connection(kind: kind, name: "Fixture", openInFinderAfterMount: false)
}

@MainActor private func fsAppModelWait(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition() {
    guard ContinuousClock.now < deadline else { throw ConnectionError.timeout }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor @Test func fsAppModelDisabledExtensionPromptsBeforeAnyMountAndCanRecover() async throws {
  let harness = FSAppModelHarness()
  defer { harness.clean() }
  harness.enabled = false
  let connection = fsAppModelConnection()
  let model = try harness.model(connections: [connection])
  #expect(model.fileSystemState == .checking)
  await model.toggleConnection(connection)
  #expect(model.fileSystemState == .disabled)
  #expect(harness.mounts == 0)
  #expect(harness.entries.isEmpty)
  #expect(harness.alerts.count == 1)
  #expect(harness.alerts.first?.title == L("启用文件系统扩展"))
  #expect(harness.alerts.first?.buttons == [L("打开系统设置"), L("取消")])
  #expect(harness.settings == 1)

  harness.enabled = true
  await model.toggleConnection(connection)
  #expect(model.fileSystemState == .enabled)
  #expect(harness.mounts == 1)
  #expect(model.connections.mountedCount == 1)
  model.prepareToQuit()
  #expect(await model.finishQuitting())
}

@MainActor @Test func fsAppModelFailedQuitKeepsVolumesAndAllowsAnotherOperation() async throws {
  let harness = FSAppModelHarness()
  defer { harness.clean() }
  let connection = fsAppModelConnection()
  let model = try harness.model(connections: [connection])
  await model.toggleConnection(connection)
  #expect(harness.mounts == 1)
  harness.unmountFailure = POSIXError(.EBUSY)
  model.prepareToQuit()
  #expect(model.operations.isStopping)
  #expect(await model.finishQuitting() == false)
  #expect(!model.operations.isStopping)
  #expect(harness.entries.count == 1)
  #expect(harness.alerts.last?.title == L("无法退出 Kayoi"))

  harness.unmountFailure = nil
  let ejected = model.operations.start(connectionID: connection.id) {
    await model.toggleConnection(connection)
  }
  await ejected.value
  #expect(harness.entries.isEmpty)
  #expect(model.connections.states[connection.id] == .disconnected)
  let remounted = model.operations.start(connectionID: connection.id) {
    await model.toggleConnection(connection)
  }
  await remounted.value
  #expect(harness.mounts == 2)
  #expect(model.connections.mountedCount == 1)
  model.prepareToQuit()
  #expect(await model.finishQuitting())
  #expect(harness.entries.isEmpty)
}

@MainActor @Test func fsAppModelDistributedLoginExpiryOnlyMarksSavedCloudAndSurvivesRefresh() async throws {
  let harness = FSAppModelHarness()
  defer { harness.clean() }
  let cloud = fsAppModelConnection()
  let phone = fsAppModelConnection(.androidUSB)
  let system = fsAppModelConnection(.smb)
  let model = try harness.model(connections: [cloud, phone, system])
  harness.entries = [try harness.entry(cloud)]
  model.connections.refreshMounts()
  #expect(model.connections.mountedCount == 1)
  model.observeFileSystemLoginEvents()
  model.observeFileSystemLoginEvents()

  let center = DistributedNotificationCenter.default()
  let deliveries = Mutex(0)
  let witness = center.addObserver(forName: FileSystemLoginEvent.notification,
    object: cloud.id.uuidString, queue: .main) { _ in deliveries.withLock { $0 += 1 } }
  defer { center.removeObserver(witness) }
  for object in [UUID().uuidString, phone.id.uuidString, system.id.uuidString, "invalid"] {
    center.postNotificationName(FileSystemLoginEvent.notification, object: object,
                               userInfo: nil, deliverImmediately: true)
  }
  center.postNotificationName(FileSystemLoginEvent.notification, object: cloud.id.uuidString,
                             userInfo: nil, deliverImmediately: true)
  try await fsAppModelWait {
    model.connections.states[cloud.id] == .needsLogin && harness.notifications.count == 1
  }
  #expect(model.connections.states[phone.id] != .needsLogin)
  #expect(model.connections.states[system.id] != .needsLogin)
  #expect(harness.notifications.first?.content.title == L("需要重新登录"))

  center.postNotificationName(FileSystemLoginEvent.notification, object: cloud.id.uuidString,
                             userInfo: nil, deliverImmediately: true)
  try await fsAppModelWait { deliveries.withLock { $0 } >= 2 }
  for _ in 0..<3 { await Task.yield() }
  model.connections.refreshMounts()
  await model.connections.refreshMountSpace()
  #expect(model.connections.states[cloud.id] == .needsLogin)
  #expect(harness.notifications.count == 1)
  #expect(harness.entries.count == 1)
}

@MainActor @Test func fsAppModelCacheReadFailureThrowsInsteadOfReportingZero() async throws {
  let harness = FSAppModelHarness()
  defer { harness.clean() }
  let model = try harness.model(connections: [])
  #expect(try await model.cacheSize() == 0)
  let root = harness.location.dataDirectory.appending(path: "FileSystemCache")
  try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
  let original = Data("not a cache directory".utf8)
  try original.write(to: root)
  await #expect(throws: POSIXError(.ENOTDIR)) { _ = try await model.cacheSize() }
  #expect(try Data(contentsOf: root) == original)

  try FileManager.default.removeItem(at: root)
  let read = root.appending(path: UUID().uuidString).appending(path: "Read")
  try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
  try Data(repeating: 1, count: 128).write(to: read.appending(path: "file.data"))
  #expect(try await model.cacheSize() == 128)
}
