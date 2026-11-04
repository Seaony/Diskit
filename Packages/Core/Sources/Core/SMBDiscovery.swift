import Foundation
import Observation

public struct DiscoveredSMB: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var host: String?
  public init(id: String, name: String, host: String? = nil) {
    self.id = id
    self.name = name
    self.host = host
  }
}

@MainActor @Observable public final class SMBDiscovery: NSObject, @preconcurrency NetServiceDelegate
{
  public private(set) var devices: [DiscoveredSMB] = []
  public private(set) var issue: SMBDiscoveryIssue?
  public var error: String? { issue?.message }
  private let makeBrowser: () -> any SMBDiscoveryBrowsing
  private let resolve: (NetService, TimeInterval) -> Void
  private let retryDelay: Duration
  private var browser: (any SMBDiscoveryBrowsing)?
  private var generation = 0
  private var services: [String: NetService] = [:]
  private var records: [String: SMBServiceRecord] = [:]
  private var hosts: [String: String] = [:]
  private var attempts: [String: Int] = [:]
  private var retries: [String: Task<Void, Never>] = [:]
  private var browserIssue: SMBDiscoveryIssue?
  private var unresolved = Set<String>()

  public override init() {
    makeBrowser = { NativeSMBBrowser() }
    resolve = { $0.resolve(withTimeout: $1) }
    retryDelay = .seconds(2)
    super.init()
  }

  init(
    makeBrowser: @escaping () -> any SMBDiscoveryBrowsing,
    resolve: @escaping (NetService, TimeInterval) -> Void, retryDelay: Duration = .seconds(2)
  ) {
    self.makeBrowser = makeBrowser
    self.resolve = resolve
    self.retryDelay = retryDelay
    super.init()
  }

  public func start() {
    guard browser == nil else { return }
    generation += 1
    let current = generation
    let next = makeBrowser()
    browser = next
    next.event = { [weak self] event in
      guard let self, self.generation == current else { return }
      switch event {
      case .results(let values): self.update(values)
      case .ready:
        self.browserIssue = nil
        self.updateIssue()
      case .waiting(let failure):
        self.browserIssue = failure
        self.updateIssue()
      case .failed(let failure):
        self.stop()
        self.browserIssue = failure
        self.updateIssue()
      }
    }
    next.start()
  }

  public func stop() {
    generation += 1
    browser?.event = nil
    browser?.cancel()
    browser = nil
    for service in services.values {
      service.delegate = nil
      service.stop()
    }
    for task in retries.values { task.cancel() }
    services.removeAll()
    records.removeAll()
    hosts.removeAll()
    attempts.removeAll()
    retries.removeAll()
    devices.removeAll()
    unresolved.removeAll()
    browserIssue = nil
    issue = nil
  }

  public func restart() {
    stop()
    start()
  }

  private func update(_ values: [SMBServiceRecord]) {
    let ids = Set(values.map(\.id))
    for id in Array(records.keys) where !ids.contains(id) {
      services.removeValue(forKey: id)?.stop()
      retries.removeValue(forKey: id)?.cancel()
      records.removeValue(forKey: id)
      hosts.removeValue(forKey: id)
      attempts.removeValue(forKey: id)
      unresolved.remove(id)
    }
    for value in values { records[value.id] = value }
    devices = values.map { value in
      DiscoveredSMB(id: value.id, name: value.name, host: hosts[value.id])
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    for value in values where services[value.id] == nil && retries[value.id] == nil {
      beginResolution(value)
    }
    updateIssue()
  }

  private func beginResolution(_ record: SMBServiceRecord) {
    guard records[record.id] != nil, (attempts[record.id] ?? 0) < 3 else { return }
    attempts[record.id, default: 0] += 1
    let service = NetService(domain: record.domain, type: record.type, name: record.name)
    services[record.id] = service
    service.delegate = self
    resolve(service, RemoteTimeout.deviceRequest)
  }

  public func netServiceDidResolveAddress(_ sender: NetService) {
    resolved(sender, host: sender.hostName)
  }

  func resolved(_ sender: NetService, host: String?) {
    guard let id = services.first(where: { $0.value === sender })?.key,
      let index = devices.firstIndex(where: { $0.id == id }), let host, !host.isEmpty
    else { return }
    hosts[id] = host
    devices[index].host = host
    unresolved.remove(id)
    updateIssue()
  }

  public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard let id = services.first(where: { $0.value === sender })?.key,
      let record = records[id]
    else { return }
    sender.delegate = nil
    sender.stop()
    services.removeValue(forKey: id)
    hosts.removeValue(forKey: id)
    if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].host = nil }
    unresolved.insert(id)
    updateIssue()
    guard (attempts[id] ?? 0) < 3, retries[id] == nil else { return }
    let current = generation
    retries[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: self.retryDelay) } catch { return }
      guard self.generation == current, self.records[id] != nil else { return }
      self.retries.removeValue(forKey: id)
      self.beginResolution(record)
    }
  }

  private func updateIssue() {
    issue = browserIssue ?? (unresolved.isEmpty ? nil : .resolutionFailed)
  }
}
