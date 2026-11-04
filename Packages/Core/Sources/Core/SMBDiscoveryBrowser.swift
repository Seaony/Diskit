import Foundation
import Network
import dnssd

struct SMBServiceRecord: Hashable, Sendable {
  let name: String
  let type: String
  let domain: String
  var id: String { "\(name).\(type).\(domain)" }
}

public enum SMBDiscoveryIssue: Equatable, Sendable {
  case permissionDenied, networkUnavailable, resolutionFailed, failed

  static func from(_ error: NWError) -> Self {
    switch error {
    case .posix(.EACCES), .posix(.EPERM): return .permissionDenied
    case .dns(let code)
    where [
      Int32(kDNSServiceErr_PolicyDenied), Int32(kDNSServiceErr_NotPermitted),
      Int32(kDNSServiceErr_NoAuth),
    ]
    .contains(code):
      return .permissionDenied
    case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): return .networkUnavailable
    case .dns(Int32(kDNSServiceErr_NoRouter)): return .networkUnavailable
    default: return .failed
    }
  }

  var message: String {
    switch self {
    case .permissionDenied: L("无法发现局域网设备，请检查本地网络权限")
    case .networkUnavailable: L("暂时无法发现局域网设备，请检查网络连接")
    case .resolutionFailed: L("设备地址解析失败，可手动填写主机地址")
    case .failed: L("无法发现局域网设备，请稍后重试")
    }
  }
}

enum SMBBrowseEvent: Sendable {
  case results([SMBServiceRecord])
  case ready
  case waiting(SMBDiscoveryIssue)
  case failed(SMBDiscoveryIssue)
}

@MainActor protocol SMBDiscoveryBrowsing: AnyObject {
  var event: ((SMBBrowseEvent) -> Void)? { get set }
  func start()
  func cancel()
}

@MainActor final class NativeSMBBrowser: SMBDiscoveryBrowsing {
  var event: ((SMBBrowseEvent) -> Void)?
  private let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)

  func start() {
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let records = results.compactMap { result -> SMBServiceRecord? in
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
        return SMBServiceRecord(name: name, type: type, domain: domain)
      }
      Task { @MainActor in self?.event?(.results(records)) }
    }
    browser.stateUpdateHandler = { [weak self] state in
      let event: SMBBrowseEvent
      switch state {
      case .ready: event = .ready
      case .waiting(let error): event = .waiting(.from(error))
      case .failed(let error): event = .failed(.from(error))
      default: return
      }
      Task { @MainActor in self?.event?(event) }
    }
    browser.start(queue: .main)
  }

  func cancel() {
    browser.browseResultsChangedHandler = nil
    browser.stateUpdateHandler = nil
    browser.cancel()
  }
}
