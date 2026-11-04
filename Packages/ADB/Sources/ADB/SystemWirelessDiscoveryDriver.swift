import Core
import Foundation
import Network

// 只将系统发现和地址解析回调转换为可替换的驱动事件。
@MainActor
final class SystemWirelessDiscoveryDriver: NSObject, WirelessDiscoveryDriver, @preconcurrency NetServiceDelegate {
  private var browsers: [WirelessServiceType: NWBrowser] = [:]
  private var services: [String: NetService] = [:]
  private var completions: [String: @MainActor (Result<(String?, Int), Error>) -> Void] = [:]

  func start(type: WirelessServiceType, snapshot: @escaping @MainActor ([WirelessDevice]) -> Void,
             failure: @escaping @MainActor (NWError) -> Void) {
    let browser = NWBrowser(for: .bonjour(type: type.rawValue, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in
      let devices = results.compactMap { result -> WirelessDevice? in
        guard case .service(let name, _, let domain, let interface) = result.endpoint else { return nil }
        return WirelessDevice(name: name, type: type, domain: domain, interface: interface)
      }
      Task { @MainActor in snapshot(devices) }
    }
    browser.stateUpdateHandler = { state in
      switch state {
      case .failed(let error), .waiting(let error): Task { @MainActor in failure(error) }
      default: break
      }
    }
    browsers[type] = browser
    browser.start(queue: .main)
  }

  func resolve(_ device: WirelessDevice,
               completion: @escaping @MainActor (Result<(String?, Int), Error>) -> Void) {
    let service = NetService(domain: device.domain, type: device.type.rawValue, name: device.name)
    services[device.id] = service
    completions[device.id] = completion
    service.delegate = self
    service.resolve(withTimeout: RemoteTimeout.deviceRequest)
  }

  func stopResolution(_ id: String) {
    services.removeValue(forKey: id)?.stop()
    completions.removeValue(forKey: id)
  }

  func stop() {
    for browser in browsers.values { browser.cancel() }
    browsers.removeAll()
    for id in Array(services.keys) { stopResolution(id) }
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard let id = services.first(where: { $0.value === sender })?.key else { return }
    completions[id]?(.success((sender.hostName, sender.port)))
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard let id = services.first(where: { $0.value === sender })?.key else { return }
    completions[id]?(.failure(RemoteError.protocolError))
  }
}
