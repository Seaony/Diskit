import Core
import Foundation
import Network
import Observation

public enum WirelessServiceType: String, Sendable, CaseIterable {
  case pairing = "_adb-tls-pairing._tcp"
  case connect = "_adb-tls-connect._tcp"
}

public struct WirelessDevice: Identifiable, Equatable, Sendable {
  public var id: String { "\(type.rawValue)|\(domain)|\(name)" }
  public let name: String
  public let type: WirelessServiceType
  public let domain: String
  public var host: String?
  public var port: UInt16?
  public let interface: NWInterface?
  public var endpoint: NWEndpoint {
    .service(name: name, type: type.rawValue, domain: domain, interface: interface)
  }
  public init(
    name: String, type: WirelessServiceType, domain: String = "local.", host: String? = nil,
    port: UInt16? = nil, interface: NWInterface? = nil
  ) {
    self.name = name
    self.type = type
    self.domain = domain
    self.host = host
    self.port = port
    self.interface = interface
  }
}

public enum WirelessRoute: Equatable, Sendable {
  case usb(ADBDevice)
  case wifi(WirelessDevice)
}

public enum WirelessSelection {
  // AOSP daemon/mdns.cpp 将整个持久化 GUID 用作连接服务名。
  public static func matches(guid: String, service: WirelessDevice) -> Bool {
    !guid.isEmpty && service.type == .connect && service.name == guid
  }

  // AOSP 格式为 adb-<serial>-<六位字母数字>，serial 本身可以含连字符。
  public static func serial(fromGUID guid: String) -> String? {
    guard guid.hasPrefix("adb-"), let separator = guid.lastIndex(of: "-") else { return nil }
    let serialStart = guid.index(guid.startIndex, offsetBy: 4)
    guard separator > serialStart else { return nil }
    let suffix = guid[guid.index(after: separator)...]
    guard suffix.utf8.count == 6,
      suffix.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      })
    else { return nil }
    return String(guid[serialStart..<separator])
  }

  public static func select(
    guid: String, usbSerial: String?, usbDevices: [ADBDevice], services: [WirelessDevice]
  ) -> WirelessRoute? {
    if let usbSerial, !usbSerial.isEmpty,
      let device = usbDevices.first(where: { $0.serial == usbSerial })
    {
      return .usb(device)
    }
    if let service = services.first(where: { matches(guid: guid, service: $0) }) {
      return .wifi(service)
    }
    return nil
  }
}

@MainActor @Observable
public final class WirelessDiscovery: NSObject,
  @preconcurrency NetServiceDelegate
{
  public private(set) var devices: [WirelessDevice] = []
  public private(set) var error: String?
  public var changed: (([WirelessDevice]) -> Void)?
  private var browsers: [WirelessServiceType: NWBrowser] = [:]
  private var snapshots: [WirelessServiceType: [WirelessDevice]] = [:]
  private var services: [String: NetService] = [:]
  private var generation = 0

  public override init() { super.init() }

  public func start() {
    guard browsers.isEmpty else { return }
    generation += 1
    let generation = generation
    error = nil
    for type in WirelessServiceType.allCases {
      let browser = NWBrowser(for: .bonjour(type: type.rawValue, domain: nil), using: .tcp)
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.update(results, type: type)
        }
      }
      browser.stateUpdateHandler = { [weak self] state in
        if case .failed = state {
          Task { @MainActor in
            guard let self, self.generation == generation else { return }
            self.error = L("无法发现无线调试设备，请检查本地网络权限")
          }
        }
      }
      browsers[type] = browser
      browser.start(queue: .main)
    }
  }

  public func stop() {
    generation += 1
    for browser in browsers.values { browser.cancel() }
    for service in services.values { service.stop() }
    browsers.removeAll()
    snapshots.removeAll()
    services.removeAll()
    devices = []
    error = nil
    changed?(devices)
  }

  private func update(_ results: Set<NWBrowser.Result>, type: WirelessServiceType) {
    var current: [WirelessDevice] = []
    for result in results {
      guard case .service(let name, _, let domain, let interface) = result.endpoint else {
        continue
      }
      var device = WirelessDevice(name: name, type: type, domain: domain, interface: interface)
      if let service = services[device.id] {
        device.host = service.hostName
        device.port = UInt16(exactly: service.port).flatMap { $0 == 0 ? nil : $0 }
      } else {
        let service = NetService(domain: domain, type: type.rawValue, name: name)
        services[device.id] = service
        service.delegate = self
        service.resolve(withTimeout: 15)
      }
      current.append(device)
    }
    snapshots[type] = current
    let liveIDs = Set(snapshots.values.flatMap { $0.map(\.id) })
    for id in Array(services.keys) where !liveIDs.contains(id) {
      services.removeValue(forKey: id)?.stop()
    }
    publish()
  }

  private func publish() {
    devices = snapshots.values.flatMap { $0 }.sorted { $0.id < $1.id }
    changed?(devices)
  }

  public func netServiceDidResolveAddress(_ sender: NetService) {
    guard let id = services.first(where: { $0.value === sender })?.key else { return }
    for type in WirelessServiceType.allCases {
      guard let index = snapshots[type]?.firstIndex(where: { $0.id == id }) else { continue }
      snapshots[type]?[index].host = sender.hostName
      snapshots[type]?[index].port = UInt16(exactly: sender.port).flatMap { $0 == 0 ? nil : $0 }
    }
    publish()
  }

  public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard services.values.contains(where: { $0 === sender }) else { return }
    error = L("无线设备地址解析失败，请检查手机上的无线调试")
  }

  public nonisolated static func resolve(guid: String) async throws -> NWEndpoint {
    guard !guid.isEmpty else { throw RemoteError.invalidPath }
    return try await WirelessResolver(guid: guid).run()
  }
}

// CLI 只等待 Bonjour 服务名，让 NWConnection 解析当下地址和端口。
private actor WirelessResolver {
  private let guid: String
  private var browser: NWBrowser?
  private var continuation: CheckedContinuation<NWEndpoint, Error>?
  private var timeout: Task<Void, Never>?

  init(guid: String) { self.guid = guid }

  func run() async throws -> NWEndpoint {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let browser = NWBrowser(
          for: .bonjour(type: WirelessServiceType.connect.rawValue, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
          Task { await self.received(results) }
        }
        browser.stateUpdateHandler = { state in
          switch state {
          case .failed(let error): Task { await self.finish(.failure(error)) }
          case .cancelled: Task { await self.finish(.failure(CancellationError())) }
          default: break
          }
        }
        self.browser = browser
        browser.start(queue: .global())
        timeout = Task {
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          self.finish(.failure(RemoteError.posix(ETIMEDOUT)))
        }
      }
    } onCancel: {
      Task { await self.finish(.failure(CancellationError())) }
    }
  }

  private func received(_ results: Set<NWBrowser.Result>) {
    for result in results {
      guard case .service(let name, _, _, _) = result.endpoint, name == guid else { continue }
      finish(.success(result.endpoint))
      return
    }
  }

  private func finish(_ result: Result<NWEndpoint, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    browser?.cancel()
    browser = nil
    continuation.resume(with: result)
  }
}
