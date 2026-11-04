import Core
import Foundation
import Observation

public enum USBDiscoveryIssue: Sendable {
  case permissionDenied, networkUnavailable, resolutionFailed, failed
}

@MainActor protocol USBDiscoverySource {
  func start(changed: @escaping @MainActor () -> Void) throws
  func devices() throws -> [ADBDevice]
  func stop()
}

@MainActor @Observable public final class USBDiscovery {
  public private(set) var devices: [ADBDevice] = []
  public private(set) var issue: USBDiscoveryIssue?
  public var changed: (([ADBDevice]) -> Void)?
  private let source: any USBDiscoverySource
  private var running = false
  private var generation = 0
  public convenience init() { self.init(source: SystemUSBMonitor()) }
  init(source: any USBDiscoverySource) { self.source = source }
  isolated deinit { source.stop() }
  public func start() {
    guard !running else { return }
    running = true
    generation += 1
    let current = generation
    issue = nil
    do {
      try source.start { [weak self] in
        guard let self, self.running, self.generation == current else { return }
        self.scan()
      }
      scan()
    } catch {
      stop()
      issue = Self.classify(error)
    }
  }
  private func scan() {
    do {
      devices = try source.devices()
      issue = nil
      changed?(devices)
    } catch { issue = Self.classify(error) }
  }
  static func classify(_ error: Error) -> USBDiscoveryIssue {
    let error = USBTransport.mappedError(error) as NSError
    return error.code == Int(EACCES) || error.code == Int(EPERM) ? .permissionDenied : .failed
  }
  public func stop() {
    guard running else { return }
    running = false
    generation += 1
    source.stop()
    devices = []
    issue = nil
    changed?(devices)
  }
}
