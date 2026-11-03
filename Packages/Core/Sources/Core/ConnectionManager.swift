import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
  case disconnected, connecting
  case mounted(MountedShare)
  case tested(SpaceInfo)
  case failed(String)
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
  public var mountFailed: ((String) -> Void)?
  public var testRemote: ((Connection) async throws -> SpaceInfo)?
  public var openInFinder: ((URL) -> Void)?
  public init(
    location: any StorageLocation = LocalStorageLocation(),
    secrets: any SecretStore = LoginKeychainStore(), smb: any SMBServing
  ) {
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
  public func savedPassword(_ connection: Connection) throws -> String {
    guard let data = try secrets.read(connection.passwordKey) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  public func listShares(host: String, user: String, password: String) async throws -> [String] {
    try await smb.shares(host: host, user: user, password: password)
  }
  public func save(_ connection: Connection, password: String) async throws {
    guard loadError == nil else { throw ConnectionError.unsupportedVersion }
    guard !busy.contains(connection.id) else { throw ConnectionError.busy }
    guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConnectionError.invalidFields
    }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    var oldSecret: Data?
    if connection.kind == .smb {
      guard let host = connection.params["host"], !host.isEmpty,
        let user = connection.params["username"], !user.isEmpty,
        let share = connection.params["share"], !share.isEmpty
      else { throw ConnectionError.invalidFields }
      try await smb.test(connection, password: password)
      oldSecret = try secrets.read(connection.passwordKey)
      try secrets.write(Data(password.utf8), for: connection.passwordKey)
    } else {
      guard let testRemote else { throw ConnectionError.notImplemented }
      states[connection.id] = .connecting
      do {
        states[connection.id] = remoteState(
          connection, result: .tested(try await testRemote(connection)))
      } catch {
        states[connection.id] = remoteState(connection, result: .failed(error.localizedDescription))
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
      if connection.kind == .smb {
        if let oldSecret {
          try secrets.write(oldSecret, for: connection.passwordKey)
        } else {
          try secrets.delete(connection.passwordKey)
        }
      }
      throw error
    }
    connections = updated
    refreshMounts()
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
  public func remove(_ connection: Connection) async throws {
    guard !busy.contains(connection.id) else { throw ConnectionError.busy }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    if let mount = smb.mounted(connection) { try await smb.unmount(mount.url) }
    try secrets.delete(connection.passwordKey)
    let cache = location.cacheDirectory.appending(path: connection.id.uuidString)
    if FileManager.default.fileExists(atPath: cache.path) {
      try FileManager.default.removeItem(at: cache)
    }
    var updated = connections.filter { $0.id != connection.id }
    for index in updated.indices { updated[index].order = index }
    try repository.save(updated)
    connections = updated
    states.removeValue(forKey: connection.id)
  }
  public func toggle(_ connection: Connection) async {
    guard !busy.contains(connection.id) else { return }
    busy.insert(connection.id)
    defer { busy.remove(connection.id) }
    if connection.kind != .smb {
      states[connection.id] = .connecting
      do {
        guard let testRemote else { throw ConnectionError.notImplemented }
        states[connection.id] = remoteState(
          connection, result: .tested(try await testRemote(connection)))
      } catch {
        states[connection.id] = remoteState(connection, result: .failed(error.localizedDescription))
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
      states[connection.id] = remoteState(connection, result: .failed(error.localizedDescription))
      if current == nil { mountFailed?(error.localizedDescription) }
    }
  }
  public func refreshMounts() {
    for connection in connections where connection.kind == .smb && !busy.contains(connection.id) {
      if let mounted = smb.mounted(connection) {
        states[connection.id] = .mounted(mounted)
      } else if case .failed = states[connection.id] {
      } else {
        states[connection.id] = .disconnected
      }
    }
  }
  private func remoteState(_ connection: Connection, result: ConnectionState) -> ConnectionState {
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
    return result
  }
  public func ricohDevicesChanged(serials: Set<String>) {
    ricohSerials = serials
    for connection in connections
    where connection.kind == .ricohGR && !serials.contains(connection.params["serial"] ?? "") {
      states[connection.id] = .disconnected
    }
  }
  public func wirelessGUIDsChanged(_ guids: Set<String>) {
    wifiGUIDs = guids
    for connection in connections
    where connection.kind == .androidWiFi && !guids.contains(connection.params["guid"] ?? "") {
      states[connection.id] = .disconnected
    }
  }
  public func usbDevicesChanged(serials: Set<String>) {
    usbSerials = serials
    for connection in connections
    where connection.kind == .androidUSB && !serials.contains(connection.params["serial"] ?? "") {
      states[connection.id] = .disconnected
    }
  }
  public func autoMount() async {
    refreshMounts()
    for connection in connections where connection.kind == .smb && connection.autoMount {
      if smb.mounted(connection) == nil { await toggle(connection) }
    }
  }
}
