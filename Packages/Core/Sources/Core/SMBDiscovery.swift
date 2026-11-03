import Foundation
import Network
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
  public private(set) var error: String?
  private var browser: NWBrowser?
  private var services: [String: NetService] = [:]
  public override init() { super.init() }
  public func start() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in
      Task { @MainActor in self.update(results) }
    }
    browser.stateUpdateHandler = { state in
      if case .failed = state { Task { @MainActor in self.error = L("无法发现局域网设备，请检查本地网络权限") } }
    }
    self.browser = browser
    browser.start(queue: .main)
  }
  private func update(_ results: Set<NWBrowser.Result>) {
    var found: [DiscoveredSMB] = []
    var current: Set<String> = []
    for result in results {
      guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
      let id = "\(name).\(type).\(domain)"
      current.insert(id)
      found.append(DiscoveredSMB(id: id, name: name, host: services[id]?.hostName))
      if services[id] == nil {
        let service = NetService(domain: domain, type: type, name: name)
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 15)
      }
    }
    for id in Array(services.keys) where !current.contains(id) {
      services.removeValue(forKey: id)?.stop()
    }
    devices = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func netServiceDidResolveAddress(_ sender: NetService) {
    guard let id = services.first(where: { $0.value === sender })?.key,
      let index = devices.firstIndex(where: { $0.id == id })
    else { return }
    devices[index].host = sender.hostName
  }
  public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    error = L("设备地址解析失败，可手动填写主机地址")
  }
}
