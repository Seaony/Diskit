import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
  case disconnected, unavailable, connecting, awaitingAuthorization, ejecting
  case mounted(MountedShare)
  case tested(SpaceInfo)
  case failed(String)
  case needsLogin
}

@MainActor @Observable public final class ConnectionManager {
  public private(set) var connections: [Connection] = []
  public private(set) var states: [UUID: ConnectionState] = [:]
  public private(set) var loadError: String?
  private let repository: ConnectionRepository
  private let secrets: any SecretStore
  private let location: any StorageLocation
  private let smb: any SMBServing
  private var busy: Set<UUID> = []
  private var refreshingSpace: Set<UUID> = []
  private var expectedUnmounts: Set<UUID> = []
  private var ownedMounts: [UUID: URL] = [:]
  private var mountingTasks: [UUID: Task<URL, Error>] = [:]
  private var autoMounting = false
  private var usbSerials: Set<String>?
  private var wifiGUIDs: Set<String>?
  private var cameraUSBSerials: Set<String>?
  public var operationFailed: ((String) -> Void)?
  public var mountFailed: ((String) -> Void)?
  public var mountFinished: ((Connection, Error?) -> Void)?
  public var unexpectedDisconnect: ((Connection) -> Void)?
  // 设了自动挂载的设备重新插上（含启动时已插着）时调用，由外面去连接
  public var deviceReturned: ((Connection) -> Void)?
  public var deviceDisappeared: ((Connection) -> Void)?
  public var loginExpired: ((Connection) -> Void)?
  public var removed: ((UUID) -> Void)?
  public var testRemote: ((Connection) async throws -> SpaceInfo)?
  public var openInFinder: ((URL) -> Void)?
  public private(set) var detailedErrors: [UUID: String] = [:]
  public init(
    location: any StorageLocation = LocalStorageLocation(),
    secrets: any SecretStore = LoginKeychainStore(), smb: any SMBServing,
    initialStates: [UUID: ConnectionState] = [:]
  ) {
    self.states = initialStates
    self.repository = ConnectionRepository(location: location)
    self.secrets = secrets
    self.smb = smb
    self.location = location
    do { connections = try repository.load() } catch { loadError = HumanError.detail(error) }
  }
  public var mountedCount: Int {
    states.values.filter {
      if case .mounted = $0 { return true }
      return false
    }.count
  }
  public var availableAutoMountDevices: [Connection] {
    connections.filter { connection in
      guard connection.autoMount else { return false }
      let key = deviceKey(connection)
      switch connection.kind {
      case .androidUSB: return usbSerials?.contains(key) == true
      case .androidWiFi: return wifiGUIDs?.contains(key) == true
      case .cameraUSB: return cameraUSBSerials?.contains(key) == true
      default: return false
      }
    }
  }

  public func savedPassword(_ connection: Connection) throws -> String {
    guard let data = try secrets.read(connection.passwordKey) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  public func listShares(host: String, user: String, password: String) async throws -> [String] {
    do { return try await smb.shares(host: host, user: user, password: password) } catch {
      reportOperationError(error)
      throw error
    }
  }
  public func save(_ connection: Connection, password: String, clearPassword: Bool = false)
    async throws
  {
    var oldSecret: Data?
    var changedSecret = false
    let previousState = states[connection.id]
    do {
      try Task.checkCancellation()
      guard loadError == nil else { throw ConnectionError.unsupportedVersion }
      guard !busy.contains(connection.id) else { throw ConnectionError.busy }
      guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConnectionError.invalidFields
      }
      busy.insert(connection.id)
      defer { busy.remove(connection.id) }
      if connection.kind.usesSystemMount {
        let guest = connection.params["guest"] == "true"
        switch connection.kind {
        case .smb:
          guard let host = connection.params["host"], !host.isEmpty,
            let share = connection.params["share"], !share.isEmpty
          else { throw ConnectionError.invalidFields }
          if !guest {
            guard let user = connection.params["username"], !user.isEmpty else {
              throw ConnectionError.invalidFields
            }
          }
        case .webdav, .webdavHTTPS:
          _ = try SystemMountAddress.url(for: connection)
        case .nfs:
          guard !(connection.params["path"] ?? "").isEmpty else {
            throw ConnectionError.invalidFields
          }
          _ = try SystemMountAddress.url(for: connection)
        default:
          throw ConnectionError.invalidFields
        }
        try await smb.test(connection, password: password)
        try Task.checkCancellation()
        if let previous = connections.first(where: { $0.id == connection.id }),
          previous.kind.usesSystemMount, let mounted = smb.mounted(previous),
          try SystemMountAddress.url(for: previous) != SystemMountAddress.url(for: connection)
        {
          try await smb.unmount(mounted.url)
          states[connection.id] = .disconnected
        }
        try Task.checkCancellation()
        oldSecret = try secrets.read(connection.passwordKey)
        changedSecret = true
        try secrets.write(Data(password.utf8), for: connection.passwordKey)
      } else {
        let previous = connections.first { $0.id == connection.id }
        let mounted = previous.flatMap { $0.kind.usesMount ? smb.mounted($0) : nil }
        let storedPassword = try secrets.read(connection.passwordKey)
        let changesPassword =
          connection.kind.usesStoredRemoteSecret
          && (clearPassword
            ? storedPassword != nil
            : !password.isEmpty && storedPassword != Data(password.utf8))
        let keepsMount =
          mounted != nil && previous?.kind == connection.kind
          && previous?.params == connection.params && !changesPassword
          && previousState != .needsLogin
        if let mounted, !keepsMount {
          try await smb.unmount(mounted.url)
          ownedMounts.removeValue(forKey: connection.id)
          states[connection.id] = .disconnected
          try Task.checkCancellation()
        }
        if changesPassword {
          oldSecret = try secrets.read(connection.passwordKey)
          changedSecret = true
          if clearPassword {
            try secrets.delete(connection.passwordKey)
          } else {
            try secrets.write(Data(password.utf8), for: connection.passwordKey)
          }
        }
        if let mounted, keepsMount {
          states[connection.id] = .mounted(mounted)
        } else {
          guard let testRemote else { throw ConnectionError.notImplemented }
          states[connection.id] = .connecting
          do {
            let result = try await testRemote(connection)
            try Task.checkCancellation()
            states[connection.id] = remoteState(connection, result: .tested(result))
          } catch {
            if error is CancellationError {
              if case .mounted = previousState {
                states[connection.id] = stateAfterCancellation(connection)
              } else {
                states[connection.id] = previousState
              }
              throw error
            }
            recordDetailedError(error, for: connection)
            states[connection.id] = remoteState(
              connection,
              result: .failed(
                displayMessage(error, kind: connection.kind)))
            throw error
          }
        }
      }
      var updated = connections
      if let index = updated.firstIndex(where: { $0.id == connection.id }) {
        var replacement = connection
        replacement.order = updated[index].order
        updated[index] = replacement
      } else {
        var added = connection
        added.order = updated.count
        updated.append(added)
      }
      try Task.checkCancellation()
      try repository.save(updated)
      changedSecret = false
      connections = updated
      detailedErrors.removeValue(forKey: connection.id)
      if connection.kind.usesSystemMount, states[connection.id] == nil {
        states[connection.id] = .disconnected
      }
      refreshMounts()
    } catch {
      if changedSecret {
        do {
          if let oldSecret {
            try secrets.write(oldSecret, for: connection.passwordKey)
          } else {
            try secrets.delete(connection.passwordKey)
          }
        } catch let rollbackError {
          detailedErrors[connection.id] =
            HumanError.detail(error, kind: connection.kind)
            + "\n"
            + LF("恢复原凭据失败：%@", HumanError.detail(rollbackError, kind: connection.kind))
          reportOperationError(rollbackError)
        }
      }
      reportOperationError(error)
      throw error
    }
  }

  public func setPresentation(id: UUID, name: String, color: String) throws {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    var updated = connections
    updated[index].name = name
    updated[index].color = color
    try repository.save(updated)
    connections = updated
  }

  public func reorder(_ id: UUID, before target: UUID?) throws {
    guard let from = connections.firstIndex(where: { $0.id == id }), id != target else { return }
    var updated = connections
    let item = updated.remove(at: from)
    let to: Int
    if let target {
      guard let index = updated.firstIndex(where: { $0.id == target }) else { return }
      to = index
    } else {
      to = updated.endIndex
    }
    updated.insert(item, at: to)
    for index in updated.indices { updated[index].order = index }
    try repository.save(updated)
    connections = updated
  }
  public func move(_ id: UUID, offset: Int) throws {
    guard let from = connections.firstIndex(where: { $0.id == id }) else { return }
    let to = from + offset
    guard connections.indices.contains(to) else { return }
    var updated = connections
    let item = updated.remove(at: from)
    updated.insert(item, at: to)
    for index in updated.indices { updated[index].order = index }
    try repository.save(updated)
    connections = updated
  }
  public func remove(_ connection: Connection) async throws {
    guard !busy.contains(connection.id) else { throw ConnectionError.busy }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    if connection.kind.usesMount, let mount = smb.mounted(connection) {
      do { try await smb.unmount(mount.url) } catch {
        reportOperationError(error)
        throw error
      }
      states[connection.id] = .disconnected
      ownedMounts.removeValue(forKey: connection.id)
    }
    var updated = connections.filter { $0.id != connection.id }
    for index in updated.indices { updated[index].order = index }
    try repository.save(updated)
    connections = updated
    states.removeValue(forKey: connection.id)
    expectedUnmounts.remove(connection.id)
    detailedErrors.removeValue(forKey: connection.id)
    removed?(connection.id)
    let deletingSecrets = RecoverableSecretStore(base: secrets)
    try deletingSecrets.delete(connection.passwordKey)
    switch connection.kind {
    case .quark, .ucDrive:
      try deletingSecrets.delete("\(connection.id.uuidString).cookie")
    case .pikPak, .tianyiDrive:
      try deletingSecrets.delete(
        "\(connection.id.uuidString).oauth.\(connection.kind.rawValue)")
    default:
      break
    }
    let cache = location.cacheDirectory.appending(path: connection.id.uuidString)
    if FileManager.default.fileExists(atPath: cache.path) {
      try FileManager.default.removeItem(at: cache)
    }
  }
  public func eject(_ connection: Connection) async {
    guard connection.kind.usesMount, !busy.contains(connection.id) else { return }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    guard let mounted = smb.mounted(connection) else {
      states[connection.id] = .disconnected
      detailedErrors.removeValue(forKey: connection.id)
      return
    }
    states[connection.id] = .ejecting
    do {
      try await smb.unmount(mounted.url)
      states[connection.id] = .disconnected
      ownedMounts.removeValue(forKey: connection.id)
      detailedErrors.removeValue(forKey: connection.id)
    } catch is CancellationError {
      states[connection.id] = stateAfterCancellation(connection)
    } catch {
      reportOperationError(error)
      recordDetailedError(error, for: connection)
      states[connection.id] = .failed(displayMessage(error, kind: connection.kind))
    }
  }

  public func connectIfNeeded(_ connection: Connection) async {
    guard states[connection.id] != .needsLogin else { return }
    if connection.kind.usesMount {
      guard remoteState(connection, result: .connecting) != .disconnected else { return }
      await mountIfNeeded(connection)
    } else {
      await toggle(connection)
    }
  }

  public func ejectOwnedVolumes(onFailure: ((Connection, Error) -> Void)? = nil) async throws {
    var failure: Error?
    for (id, url) in ownedMounts {
      guard let connection = connections.first(where: { $0.id == id }), connection.kind != .smb
      else {
        continue
      }
      guard smb.mounted(connection)?.url == url else {
        ownedMounts.removeValue(forKey: id)
        continue
      }
      do {
        try await smb.unmount(url)
        ownedMounts.removeValue(forKey: id)
        states[id] = .disconnected
      } catch {
        onFailure?(connection, error)
        recordDetailedError(error, for: connection)
        if failure == nil { failure = error }
      }
    }
    if let failure { throw failure }
  }

  public func toggle(_ connection: Connection) async {
    guard !Task.isCancelled, !busy.contains(connection.id) else { return }
    if states[connection.id] == .awaitingAuthorization {
      states[connection.id] = .disconnected
      return
    }
    if connection.kind.usesMount {
      if smb.mounted(connection) != nil {
        await eject(connection)
      } else {
        await mountIfNeeded(connection)
      }
      return
    }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    states[connection.id] = .connecting
    do {
      guard let testRemote else { throw ConnectionError.notImplemented }
      let result = try await testRemote(connection)
      try Task.checkCancellation()
      states[connection.id] = remoteState(connection, result: .tested(result))
      detailedErrors.removeValue(forKey: connection.id)
    } catch is CancellationError {
      states[connection.id] = stateAfterCancellation(connection)
    } catch {
      let needsLogin = isLoginFailure(error, kind: connection.kind)
      if needsLogin { loginExpired?(connection) }
      reportOperationError(error)
      recordDetailedError(error, for: connection)
      states[connection.id] =
        needsLogin
        ? .needsLogin
        : remoteState(connection, result: .failed(displayMessage(error, kind: connection.kind)))
    }
  }

  private func mountIfNeeded(_ connection: Connection) async {
    guard !Task.isCancelled, !busy.contains(connection.id), states[connection.id] != .needsLogin
    else { return }
    if let mounted = smb.mounted(connection) {
      states[connection.id] = .mounted(mounted)
      detailedErrors.removeValue(forKey: connection.id)
      mountFinished?(connection, nil)
      return
    }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    states[connection.id] = .connecting
    do {
      let password = try savedPassword(connection)
      let task = Task { try await smb.mount(connection, password: password) }
      mountingTasks[connection.id] = task
      defer { mountingTasks.removeValue(forKey: connection.id) }
      let url = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      ownedMounts[connection.id] = url
      states[connection.id] = .mounted(smb.mounted(connection) ?? MountedShare(url: url))
      detailedErrors.removeValue(forKey: connection.id)
      mountFinished?(connection, nil)
      if connection.openInFinderAfterMount { openInFinder?(url) }
    } catch is CancellationError {
      states[connection.id] = stateAfterCancellation(connection)
      mountFinished?(connection, nil)
    } catch {
      let needsLogin = isLoginFailure(error, kind: connection.kind)
      if needsLogin { loginExpired?(connection) }
      reportOperationError(error)
      recordDetailedError(error, for: connection)
      states[connection.id] = remoteState(
        connection,
        result: needsLogin ? .needsLogin : .failed(displayMessage(error, kind: connection.kind)))
      mountFinished?(connection, error)
      mountFailed?(HumanError.message(error, kind: connection.kind))
    }
  }
  public func cancelIdleOperation(_ connection: Connection) {
    guard !busy.contains(connection.id),
      states[connection.id] == .connecting || states[connection.id] == .awaitingAuthorization
    else { return }
    states[connection.id] = stateAfterCancellation(connection)
  }

  private func stateAfterCancellation(_ connection: Connection) -> ConnectionState {
    if states[connection.id] == .needsLogin { return .needsLogin }
    if connection.kind.usesMount, let mounted = smb.mounted(connection) {
      return .mounted(mounted)
    }
    return .disconnected
  }

  public func reportOperationError(_ error: Error) {
    if error is CancellationError { return }
    let failure = error as NSError
    if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
    // 写进错误日志的是完整报告：每一层的错误域、错误码和原文说明，排查时不用再猜
    operationFailed?(HumanError.report(error))
  }
  public func refreshMounts() {
    for connection in connections
    where connection.kind.usesMount && !busy.contains(connection.id) {
      if let mounted = smb.mounted(connection) {
        guard states[connection.id] != .needsLogin else { continue }
        states[connection.id] = .mounted(mounted)
        expectedUnmounts.remove(connection.id)
        detailedErrors.removeValue(forKey: connection.id)
      } else if case .failed = states[connection.id] {
      } else if case .tested = states[connection.id] {
      } else if states[connection.id] == .needsLogin {
      } else {
        let wasMounted: Bool
        if case .mounted = states[connection.id] { wasMounted = true } else { wasMounted = false }
        states[connection.id] = .disconnected
        let expected = expectedUnmounts.remove(connection.id) != nil
        if wasMounted && !expected { unexpectedDisconnect?(connection) }
      }
    }
  }
  public func systemVolumeWillUnmount(at url: URL) {
    for connection in connections where connection.kind.usesMount {
      if case .mounted(let mounted) = states[connection.id],
        mounted.url.standardizedFileURL == url.standardizedFileURL
      {
        expectedUnmounts.insert(connection.id)
      }
    }
  }

  public func systemVolumeUnmounted(at url: URL) {
    for connection in connections where connection.kind.usesMount {
      if case .mounted(let mounted) = states[connection.id],
        mounted.url.standardizedFileURL == url.standardizedFileURL
      {
        states[connection.id] = .disconnected
        ownedMounts.removeValue(forKey: connection.id)
        expectedUnmounts.remove(connection.id)
        detailedErrors.removeValue(forKey: connection.id)
      }
    }
    refreshMounts()
  }

  public func refreshMountSpace() async {
    refreshMounts()
    for id in connections.map(\.id) {
      guard !Task.isCancelled, !busy.contains(id), !refreshingSpace.contains(id),
        let connection = connections.first(where: { $0.id == id }),
        case .mounted(let previous) = states[id]
      else { continue }
      refreshingSpace.insert(id)
      let refreshed = await smb.refreshMounted(connection)
      refreshingSpace.remove(id)
      guard !Task.isCancelled, !busy.contains(id),
        connections.first(where: { $0.id == id }) == connection,
        case .mounted(let current) = states[id], current.url == previous.url
      else { continue }
      guard let actual = smb.mounted(connection) else {
        states[id] = .disconnected
        if expectedUnmounts.remove(id) == nil { unexpectedDisconnect?(connection) }
        continue
      }
      guard actual.url == previous.url, let refreshed, refreshed.url == previous.url else {
        states[id] = .mounted(actual)
        continue
      }
      states[id] = .mounted(refreshed)
    }
  }

  public func requireLogin(_ id: UUID) {
    if connections.contains(where: { $0.id == id }) { states[id] = .needsLogin }
  }
  private func remoteState(_ connection: Connection, result: ConnectionState) -> ConnectionState {
    if case .failed = result, states[connection.id] == .needsLogin { return .needsLogin }
    if connection.kind == .androidUSB, let usbSerials,
      !usbSerials.contains(connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    {
      return .disconnected
    }
    if connection.kind == .androidWiFi, let wifiGUIDs,
      !wifiGUIDs.contains(connection.params["guid"] ?? "")
    {
      return .disconnected
    }
    if connection.kind == .cameraUSB, let cameraUSBSerials,
      !cameraUSBSerials.contains(connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    {
      return .disconnected
    }
    return result
  }
  public func cameraUSBDevicesChanged(serials: Set<String>) {
    let previous = cameraUSBSerials
    cameraUSBSerials = serials
    updateDevices(kind: .cameraUSB, previous: previous, current: serials)
  }
  public func wirelessGUIDsChanged(_ guids: Set<String>) {
    let previous = wifiGUIDs
    wifiGUIDs = guids
    updateDevices(kind: .androidWiFi, previous: previous, current: guids)
  }
  public func usbDevicesChanged(serials: Set<String>) {
    let previous = usbSerials
    usbSerials = serials
    updateDevices(kind: .androidUSB, previous: previous, current: serials)
  }
  private func deviceKey(_ connection: Connection) -> String {
    connection.kind == .androidWiFi
      ? connection.params["guid"] ?? ""
      : connection.params["deviceID"] ?? connection.params["serial"] ?? ""
  }
  private func updateDevices(kind: ConnectionKind, previous: Set<String>?, current: Set<String>) {
    reportReturnedDevices(kind: kind, previous: previous, current: current)
    for connection in connections
    where connection.kind == kind && !current.contains(deviceKey(connection)) {
      let wasAvailable = previous?.contains(deviceKey(connection)) == true
      if wasAvailable || previous == nil {
        deviceDisappeared(connection, wasAvailable: wasAvailable)
      }
    }
  }
  public func autoMount() async {
    guard !Task.isCancelled, !autoMounting else { return }
    autoMounting = true
    defer { autoMounting = false }
    refreshMounts()
    let candidates = connections.filter { $0.kind.usesMount && $0.autoMount }.map(\.id)
    for id in candidates {
      guard !Task.isCancelled else { return }
      guard let connection = connections.first(where: { $0.id == id }),
        connection.kind.usesMount, connection.autoMount, !busy.contains(id),
        remoteState(connection, result: .connecting) != .disconnected,
        states[id] != .needsLogin
      else { continue }
      await mountIfNeeded(connection)
    }
  }

  private func reportReturnedDevices(
    kind: ConnectionKind, previous: Set<String>?, current: Set<String>
  ) {
    for connection in connections where connection.kind == kind && connection.autoMount {
      let key =
        kind == .androidWiFi
        ? connection.params["guid"] ?? ""
        : connection.params["deviceID"] ?? connection.params["serial"] ?? ""
      guard current.contains(key), previous?.contains(key) != true, !busy.contains(connection.id)
      else {
        continue
      }
      deviceReturned?(connection)
    }
  }

  private func notifyIfConnectedDisconnects(_ connection: Connection) {
    switch states[connection.id] {
    case .mounted, .tested, .connecting: unexpectedDisconnect?(connection)
    default: break
    }
  }

  private func deviceDisappeared(_ connection: Connection, wasAvailable: Bool) {
    if wasAvailable { notifyIfConnectedDisconnects(connection) }
    mountingTasks[connection.id]?.cancel()
    if connection.kind.usesMount, let deviceDisappeared,
      smb.mounted(connection) != nil || busy.contains(connection.id)
    {
      deviceDisappeared(connection)
    } else {
      states[connection.id] = .disconnected
    }
  }

  private func displayMessage(_ error: Error, kind: ConnectionKind) -> String {
    HumanError.message(error, kind: kind)
  }

  private func isLoginFailure(_ error: Error, kind: ConnectionKind) -> Bool {
    FileSystemLoginEvent.requiresLogin(error, kind: kind)
  }

  private func recordDetailedError(_ error: Error, for connection: Connection) {
    detailedErrors[connection.id] = HumanError.detail(error, kind: connection.kind)
  }
}
