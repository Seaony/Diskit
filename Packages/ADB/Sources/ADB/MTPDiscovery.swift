import Core
import Foundation
import IOKit
import Observation

// 盯着所有 USB 接口的插拔，重新找出开着文件传输（MTP）的设备
@MainActor @Observable public final class MTPDiscovery {
  public private(set) var devices: [MTPDevice] = []
  public private(set) var issue: USBDiscoveryIssue?
  public var changed: (([MTPDevice]) -> Void)?
  @ObservationIgnored private let monitor = SystemUSBMonitor(match: {
    IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
  })
  @ObservationIgnored private var running = false
  // 第一次扫描不管有没有设备都要通知，上层靠它知道“已经扫过、确实没插”
  @ObservationIgnored private var reported = false
  // 问到的设备型号名，按接口在注册表里的编号记；问过的不再问
  @ObservationIgnored private var models: [UInt64: String] = [:]
  @ObservationIgnored private var asked: Set<UInt64> = []
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var retryIDs: Set<UInt64> = []
  // 同一进程里问型号和正式连接不能同时打开接口：连接期间不问，正在问的先问完再连
  private static var probing: Task<Void, Never>?
  private static var connects = 0
  public init() {}
  public func start() {
    guard !running else { return }
    running = true
    issue = nil
    do {
      try monitor.start { [weak self] in self?.scan() }
      scan()
    } catch {
      running = false
      monitor.stop()
      issue = USBDiscovery.classify(error)
    }
  }
  public func stop() {
    guard running else { return }
    running = false
    reported = false
    retry?.cancel()
    retry = nil
    monitor.stop()
    devices = []
    changed?(devices)
  }
  private func scan() {
    guard running else { return }
    do {
      var found = try MTPUSB.scanDevices()
      issue = nil
      // 新插上的设备先问型号再公布，提醒和列表里直接显示设备自己的名字
      let unknown = found.filter { !$0.hasADB && !asked.contains($0.registryID) }
      if !unknown.isEmpty {
        guard Self.probing == nil else { return }  // 这一轮问完会重新扫描
        if Self.connects == 0 {
          probe(unknown)
          return
        }
        retryLater([])
      }
      found = found.map { device in models[device.registryID].map { device.named($0) } ?? device }
      guard found != devices || !reported else { return }
      reported = true
      devices = found
      changed?(devices)
    } catch { issue = USBDiscovery.classify(error) }
  }

  private func probe(_ devices: [MTPDevice]) {
    asked.formUnion(devices.map(\.registryID))
    Self.probing = Task { [weak self] in
      var names: [UInt64: String] = [:]
      for device in devices {
        if let model = await MTPUSB.model(of: device) { names[device.registryID] = model }
      }
      Self.probing = nil
      guard let self else { return }
      self.models.merge(names) { _, new in new }
      // 设备睡眠、锁屏或接口被别的程序占着时问不到：先用 USB 里的名字公布，10 秒后再问
      let missed = devices.map(\.registryID).filter { names[$0] == nil }
      if !missed.isEmpty { self.retryLater(missed) }
      self.scan()
    }
  }

  private func retryLater(_ devices: [UInt64]) {
    retryIDs.formUnion(devices)
    guard retry == nil else { return }
    retry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled, let self else { return }
      self.retry = nil
      self.asked.subtract(self.retryIDs)
      self.retryIDs = []
      self.scan()
    }
  }

  // 连上设备后它报的型号：设备睡着时没问到，连上了就补上
  public func learn(model: String, for params: [String: String]) {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty, let device = try? MTPUSB.select(params: params, devices: devices),
      models[device.registryID] != model
    else { return }
    models[device.registryID] = model
    scan()
  }

  // 正式连接都包在这里面：先等正在问型号的那一轮结束，连接期间不再问
  public static func connecting<Value>(_ body: () async throws -> Value) async throws -> Value {
    connects += 1
    defer { connects -= 1 }
    await probing?.value
    return try await body()
  }
}
