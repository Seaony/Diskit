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
  private var usbSerials: Set<String>?
  private var wifiGUIDs: Set<String>?
  private var ricohSerials: Set<String>?
  private var cameraUSBSerials: Set<String>?
  public var operationFailed: ((String) -> Void)?
  public var mountFailed: ((String) -> Void)?
  public var unexpectedDisconnect: ((Connection) -> Void)?
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
    do { connections = try repository.load() } catch { loadError = error.localizedDescription }
  }
  public var mountedCount: Int {
    states.values.filter {
      if case .mounted = $0 { return true }
      return false
    }.count
  }
  public var mountsToEjectOnQuit: [Connection] {
    connections.filter { connection in
      guard connection.kind != .smb else { return false }
      if case .mounted = states[connection.id] { return true }
      return false
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
  public func save(_ connection: Connection, password: String) async throws {
    do {
      guard loadError == nil else { throw ConnectionError.unsupportedVersion }
      guard !busy.contains(connection.id) else { throw ConnectionError.busy }
      guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConnectionError.invalidFields
      }
      busy.insert(connection.id)
      defer { busy.remove(connection.id) }
      var oldSecret: Data?
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
        if let previous = connections.first(where: { $0.id == connection.id }),
          previous.kind.usesSystemMount, let mounted = smb.mounted(previous),
          try SystemMountAddress.url(for: previous) != SystemMountAddress.url(for: connection)
        {
          try await smb.unmount(mounted.url)
          states[connection.id] = .disconnected
        }
        oldSecret = try secrets.read(connection.passwordKey)
        try secrets.write(Data(password.utf8), for: connection.passwordKey)
      } else {
        if connection.kind.usesStoredRemoteSecret, !password.isEmpty {
          oldSecret = try secrets.read(connection.passwordKey)
          try secrets.write(Data(password.utf8), for: connection.passwordKey)
        }
        guard let testRemote else { throw ConnectionError.notImplemented }
        states[connection.id] = .connecting
        do {
          states[connection.id] = remoteState(
            connection, result: .tested(try await testRemote(connection)))
        } catch {
          if connection.kind.usesStoredRemoteSecret, oldSecret != nil || !password.isEmpty {
            if let oldSecret {
              try secrets.write(oldSecret, for: connection.passwordKey)
            } else {
              try secrets.delete(connection.passwordKey)
            }
          }
          recordDetailedError(error, for: connection)
          states[connection.id] = remoteState(
            connection,
            result: .failed(
              (error as? RemoteError).map { HumanError.remote($0, kind: connection.kind) }
                ?? error.localizedDescription))
          throw error
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
      do { try repository.save(updated) } catch {
        if connection.kind.usesSystemMount || connection.kind.usesStoredRemoteSecret {
          if let oldSecret {
            try secrets.write(oldSecret, for: connection.passwordKey)
          } else {
            try secrets.delete(connection.passwordKey)
          }
        }
        throw error
      }
      connections = updated
      if connection.kind.usesSystemMount, states[connection.id] == nil {
        states[connection.id] = .disconnected
      }
      refreshMounts()
    } catch {
      reportOperationError(error)
      throw error
    }
  }

  public func reorder(_ id: UUID, before target: UUID) throws {
    guard let from = connections.firstIndex(where: { $0.id == id }), id != target else { return }
    var updated = connections
    let item = updated.remove(at: from)
    guard let to = updated.firstIndex(where: { $0.id == target }) else { return }
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
    if connection.kind.usesSystemMount, let mount = smb.mounted(connection) {
      do { try await smb.unmount(mount.url) } catch {
        reportOperationError(error)
        throw error
      }
      states[connection.id] = .disconnected
    }
    var updated = connections.filter { $0.id != connection.id }
    for index in updated.indices { updated[index].order = index }
    try repository.save(updated)
    connections = updated
    states.removeValue(forKey: connection.id)
    removed?(connection.id)
    let deletingSecrets = RecoverableSecretStore(base: secrets)
    try deletingSecrets.delete(connection.passwordKey)
    switch connection.kind {
    case .aliyunDrive:
      try deletingSecrets.delete("\(connection.id.uuidString).oauth")
    case .quark, .ucDrive:
      try deletingSecrets.delete("\(connection.id.uuidString).cookie")
    case .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox, .pikPak,
      .tianyiDrive:
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
  public func toggle(_ connection: Connection) async {
    guard !busy.contains(connection.id) else { return }
    if states[connection.id] == .awaitingAuthorization {
      states[connection.id] = .disconnected
      return
    }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    if !connection.kind.usesSystemMount {
      states[connection.id] = .connecting
      do {
        guard let testRemote else { throw ConnectionError.notImplemented }
        states[connection.id] = remoteState(
          connection, result: .tested(try await testRemote(connection)))
      } catch {
        let needsLogin = isLoginFailure(error, kind: connection.kind)
        if needsLogin { loginExpired?(connection) }
        reportOperationError(error)
        recordDetailedError(error, for: connection)
        states[connection.id] =
          needsLogin
          ? .needsLogin
          : remoteState(
            connection, result: .failed(displayMessage(error, kind: connection.kind)))
        return
      }
      return
    }
    let current = smb.mounted(connection)
    states[connection.id] = .connecting
    do {
      if let current {
        try await smb.unmount(current.url)
        states[connection.id] = .disconnected
      } else {
        let url = try await smb.mount(connection, password: savedPassword(connection))
        states[connection.id] = .mounted(smb.mounted(connection) ?? MountedShare(url: url))
        if connection.openInFinderAfterMount { openInFinder?(url) }
      }
    } catch {
      reportOperationError(error)
      recordDetailedError(error, for: connection)
      states[connection.id] = remoteState(
        connection, result: .failed(displayMessage(error, kind: connection.kind)))
      if current == nil { mountFailed?(error.localizedDescription) }
    }
  }
  public func reportOperationError(_ error: Error) {
    if error is CancellationError { return }
    let message: String
    if let error = error as? ConnectionError {
      message = error.localizedDescription
    } else if let error = error as? RemoteError {
      message = error.localizedDescription
    } else {
      let failure = error as NSError
      if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
      if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut {
        message = ConnectionError.timeout.localizedDescription
      } else if failure.domain == NSPOSIXErrorDomain, let code = Int32(exactly: failure.code) {
        message = RemoteError.posix(code).localizedDescription
      } else {
        message = RemoteError.posix(EIO).localizedDescription
      }
    }
    operationFailed?(message)
  }
  public func refreshMounts() {
    for connection in connections
    where connection.kind.usesSystemMount && !busy.contains(connection.id) {
      if let mounted = smb.mounted(connection) {
        states[connection.id] = .mounted(mounted)
      } else if case .failed = states[connection.id] {
      } else {
        let wasMounted: Bool
        if case .mounted = states[connection.id] { wasMounted = true } else { wasMounted = false }
        states[connection.id] = .disconnected
        if wasMounted { unexpectedDisconnect?(connection) }
      }
    }
  }
  public func requireLogin(_ id: UUID) {
    if connections.contains(where: { $0.id == id }) { states[id] = .needsLogin }
  }
  private func remoteState(_ connection: Connection, result: ConnectionState) -> ConnectionState {
    if case .failed = result, states[connection.id] == .needsLogin { return .needsLogin }
    if connection.kind == .androidUSB, let usbSerials,
      !usbSerials.contains(connection.params["serial"] ?? "")
    {
      return .disconnected
    }
    if connection.kind == .androidWiFi, let wifiGUIDs,
      !wifiGUIDs.contains(connection.params["guid"] ?? "")
    {
      return .disconnected
    }
    if connection.kind == .ricohGR, let ricohSerials,
      !ricohSerials.contains(connection.params["serial"] ?? "")
    {
      return .disconnected
    }
    if connection.kind == .cameraUSB, let cameraUSBSerials,
      !cameraUSBSerials.contains(connection.params["serial"] ?? "")
    {
      return .disconnected
    }
    return result
  }
  public func ricohDevicesChanged(serials: Set<String>) {
    let previous = ricohSerials
    ricohSerials = serials
    for connection in connections
    where connection.kind == .ricohGR && !serials.contains(connection.params["serial"] ?? "") {
      if previous?.contains(connection.params["serial"] ?? "") == true {
        notifyIfConnectedDisconnects(connection)
      }
      states[connection.id] = .disconnected
    }
  }
  public func cameraUSBDevicesChanged(serials: Set<String>) {
    let previous = cameraUSBSerials
    cameraUSBSerials = serials
    for connection in connections
    where connection.kind == .cameraUSB && !serials.contains(connection.params["serial"] ?? "") {
      if previous?.contains(connection.params["serial"] ?? "") == true {
        notifyIfConnectedDisconnects(connection)
      }
      states[connection.id] = .disconnected
    }
  }
  public func wirelessGUIDsChanged(_ guids: Set<String>) {
    let previous = wifiGUIDs
    wifiGUIDs = guids
    for connection in connections
    where connection.kind == .androidWiFi && !guids.contains(connection.params["guid"] ?? "") {
      if previous?.contains(connection.params["guid"] ?? "") == true {
        notifyIfConnectedDisconnects(connection)
      }
      states[connection.id] = .disconnected
    }
  }
  public func usbDevicesChanged(serials: Set<String>) {
    let previous = usbSerials
    usbSerials = serials
    for connection in connections
    where connection.kind == .androidUSB && !serials.contains(connection.params["serial"] ?? "") {
      if previous?.contains(connection.params["serial"] ?? "") == true {
        notifyIfConnectedDisconnects(connection)
      }
      states[connection.id] = .disconnected
    }
  }
  public func autoMount() async {
    refreshMounts()
    for connection in connections
    where connection.kind.usesSystemMount && connection.autoMount {
      if smb.mounted(connection) == nil { await toggle(connection) }
    }
  }

  private func notifyIfConnectedDisconnects(_ connection: Connection) {
    if case .mounted = states[connection.id] { unexpectedDisconnect?(connection) }
  }

  private func displayMessage(_ error: Error, kind: ConnectionKind) -> String {
    if let error = error as? RemoteError { return HumanError.remote(error, kind: kind) }
    return error.localizedDescription
  }

  private func isLoginFailure(_ error: Error, kind: ConnectionKind) -> Bool {
    switch kind {
    case .aliyunDrive, .quark, .ucDrive, .baiduDrive, .drive115, .drive123, .oneDrive,
      .googleDrive, .dropbox, .pikPak, .tianyiDrive, .mobileCloud, .thunderDrive, .lanzou:
      break
    default:
      return false
    }
    if let remote = error as? RemoteError {
      switch remote {
      case .unauthorized:
        return true
      case .http(let status):
        return status == 401 || status == 403
      case .posix(let code):
        return code == EACCES || code == EPERM
      default:
        return false
      }
    }
    let failure = error as NSError
    return failure.domain == NSPOSIXErrorDomain
      && (failure.code == Int(EACCES) || failure.code == Int(EPERM))
  }

  private func recordDetailedError(_ error: Error, for connection: Connection) {
    detailedErrors[connection.id] = HumanError.detail(error, kind: connection.kind)
  }
}
