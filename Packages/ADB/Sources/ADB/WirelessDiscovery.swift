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

}

public enum WirelessDiscoveryIssue: Sendable {
  case permissionDenied, networkUnavailable, resolutionFailed, failed
}

@MainActor
protocol WirelessDiscoveryDriver: AnyObject {
  func start(type: WirelessServiceType, snapshot: @escaping @MainActor ([WirelessDevice]) -> Void,
             failure: @escaping @MainActor (NWError) -> Void)
  func resolve(_ device: WirelessDevice,
               completion: @escaping @MainActor (Result<(String?, Int), Error>) -> Void)
  func stopResolution(_ id: String)
  func stop()
}

@MainActor @Observable
public final class WirelessDiscovery: NSObject, @preconcurrency NetServiceDelegate {
  public private(set) var devices: [WirelessDevice] = []
  public private(set) var error: String?
  public private(set) var issue: WirelessDiscoveryIssue?
  public var changed: (([WirelessDevice]) -> Void)?
  private let driver: any WirelessDiscoveryDriver
  private var snapshots: [WirelessServiceType: [WirelessDevice]] = [:]
  private var resolving: [String: UUID] = [:]
  private var resolved: [String: (String?, Int)] = [:]
  private var generation = 0
  private var running = false

  public override convenience init() { self.init(driver: SystemWirelessDiscoveryDriver()) }
  init(driver: any WirelessDiscoveryDriver) { self.driver = driver; super.init() }

  public func start() {
    guard !running else { return }
    running = true
    generation += 1
    let generation = generation
    error = nil
    issue = nil
    for type in WirelessServiceType.allCases {
      driver.start(type: type, snapshot: { [weak self] devices in
        guard let self, self.generation == generation else { return }
        self.update(devices, type: type)
      }, failure: { [weak self] failure in
        guard let self, self.generation == generation else { return }
        self.error = L("无法发现无线调试设备，请检查本地网络权限")
        self.issue = Self.discoveryIssue(failure)
      })
    }
  }

  public func stop() {
    generation += 1
    running = false
    driver.stop()
    snapshots.removeAll()
    resolving.removeAll()
    resolved.removeAll()
    devices = []
    error = nil
    issue = nil
    changed?(devices)
  }

  private func update(_ devices: [WirelessDevice], type: WirelessServiceType) {
    snapshots[type] = devices
    // 又收到设备列表说明发现已经恢复（如网络回来了），之前的发现失败提示不再成立
    if issue != nil, issue != .resolutionFailed {
      error = nil
      issue = nil
    }
    let liveIDs = Set(snapshots.values.flatMap { $0.map(\.id) })
    for id in Set(resolving.keys).subtracting(liveIDs) {
      resolving.removeValue(forKey: id)
      resolved.removeValue(forKey: id)
      driver.stopResolution(id)
    }
    let generation = generation
    for device in devices where resolving[device.id] == nil {
      let resolution = UUID()
      resolving[device.id] = resolution
      driver.resolve(device) { [weak self] result in
        guard let self, self.generation == generation, self.resolving[device.id] == resolution else { return }
        switch result {
        case .success(let address): self.resolved[device.id] = address
        case .failure:
          self.error = L("无线设备地址解析失败，请检查手机上的无线调试")
          self.issue = .resolutionFailed
        }
        self.publish()
      }
    }
    publish()
  }

  private func publish() {
    devices = snapshots.values.flatMap { $0 }.map { device in
      var device = device
      if let address = resolved[device.id] {
        device.host = address.0
        device.port = UInt16(exactly: address.1).flatMap { $0 == 0 ? nil : $0 }
      }
      return device
    }.sorted { $0.id < $1.id }
    changed?(devices)
  }

  public func netServiceDidResolveAddress(_ sender: NetService) {
    (driver as? SystemWirelessDiscoveryDriver)?.netServiceDidResolveAddress(sender)
  }

  public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    (driver as? SystemWirelessDiscoveryDriver)?.netService(sender, didNotResolve: errorDict)
  }

  static func discoveryIssue(_ error: NWError) -> WirelessDiscoveryIssue {
    switch error {
    case .posix(.EACCES), .posix(.EPERM), .dns(-65570): return .permissionDenied
    case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.ENOTCONN): return .networkUnavailable
    default: return .failed
    }
  }

  public nonisolated static func resolve(guid: String) async throws -> NWEndpoint {
    guard !guid.isEmpty else { throw RemoteError.invalidPath }
    return try await WirelessResolver(guid: guid).run()
  }
}

@MainActor
final class WirelessResolver {
  private let guid: String
  private let driver: any WirelessDiscoveryDriver
  private let sleep: @Sendable () async throws -> Void
  private var continuation: CheckedContinuation<NWEndpoint, Error>?
  private var timeout: Task<Void, Never>?
  private var generation = 0

  init(guid: String, driver: any WirelessDiscoveryDriver = SystemWirelessDiscoveryDriver(),
       sleep: @escaping @Sendable () async throws -> Void = {
         try await Task.sleep(for: .seconds(RemoteTimeout.deviceRequest))
       }) {
    self.guid = guid
    self.driver = driver
    self.sleep = sleep
  }

  func run() async throws -> NWEndpoint {
    guard !guid.isEmpty else { throw RemoteError.invalidPath }
    guard continuation == nil else { throw RemoteError.posix(EBUSY) }
    try Task.checkCancellation()
    generation += 1
    let generation = generation
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        driver.start(type: .connect, snapshot: { [weak self] devices in
          guard let self, self.generation == generation, let device = devices.first(where: { WirelessSelection.matches(guid: self.guid, service: $0) }) else { return }
          self.finish(.success(device.endpoint))
        }, failure: { [weak self] error in
          guard let self, self.generation == generation else { return }
          self.finish(.failure(error))
        })
        guard self.continuation != nil else { return }
        timeout = Task {
          do { try await self.sleep() } catch { return }
          guard self.generation == generation else { return }
          self.finish(.failure(RemoteError.posix(ETIMEDOUT)))
        }
      }
    } onCancel: {
      Task { @MainActor in
        guard self.generation == generation else { return }
        self.finish(.failure(CancellationError()))
      }
    }
  }

  private func finish(_ result: Result<NWEndpoint, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    driver.stop()
    continuation.resume(with: result)
  }
}
