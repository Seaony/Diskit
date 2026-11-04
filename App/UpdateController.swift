import AppKit
import Combine
import Core
import Foundation
import Observation
import Sparkle

struct UpdateServiceState {
  var canCheck = false
  var automaticChecks = true
  var automaticDownloads = false
  var allowsDownloads = false
  var lastCheck: Date?
}

@MainActor protocol UpdateService: AnyObject {
  var stateChanged: ((UpdateServiceState) -> Void)? { get set }
  func start() throws
  func check()
  func setAutomaticChecks(_ enabled: Bool)
  func setAutomaticDownloads(_ enabled: Bool)
}

@MainActor struct UpdatePresentation {
  var activate: () -> Void
  var lowerObscuringWindow: () -> (() -> Void)?

  static let live = UpdatePresentation(
    activate: { NSApp.activate() },
    lowerObscuringWindow: {
      guard let window = NSApp.keyWindow, window.level > .modalPanel else { return nil }
      let level = window.level
      window.level = .normal
      return { [weak window] in window?.level = level }
    })
}

@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate
{
  private(set) var canCheckForUpdates = false
  private(set) var automaticallyChecksForUpdates = true
  private(set) var automaticallyDownloadsUpdates = false
  private(set) var allowsAutomaticUpdates = false
  private(set) var lastUpdateCheckDate: Date?
  private(set) var message: String?
  private(set) var isManualCheck = false
  @ObservationIgnored private var service: (any UpdateService)?
  @ObservationIgnored private let isDemo: Bool
  @ObservationIgnored private let presentation: UpdatePresentation
  @ObservationIgnored private var restoreWindow: (() -> Void)?

  init(
    isDemo: Bool, bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    presentation: UpdatePresentation = .live,
    serviceFactory: @MainActor (Bundle, UpdateController) -> any UpdateService = {
      SparkleUpdateService(bundle: $0, delegate: $1)
    }
  ) {
    self.isDemo = isDemo
    self.presentation = presentation
    super.init()
    guard
      UpdatePolicy.shouldStart(
        isDemo: isDemo, bundleURL: bundle.bundleURL, environment: environment)
    else {
      canCheckForUpdates = isDemo
      allowsAutomaticUpdates = isDemo
      return
    }
    guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      URL(string: feed)?.scheme == "https",
      let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32
    else {
      message = L("此版本尚未配置更新服务")
      return
    }
    let service = serviceFactory(bundle, self)
    self.service = service
    service.stateChanged = { [weak self] state in
      guard let self else { return }
      canCheckForUpdates = state.canCheck
      automaticallyChecksForUpdates = state.automaticChecks
      automaticallyDownloadsUpdates = state.automaticDownloads
      allowsAutomaticUpdates = state.allowsDownloads
      lastUpdateCheckDate = state.lastCheck
    }
    do { try service.start() } catch { message = HumanError.detail(error) }
  }

  func checkForUpdates() {
    guard canCheckForUpdates else { return }
    message = nil
    if isDemo {
      lastUpdateCheckDate = Date()
      message = L("还没有可用的更新信息")
      return
    }
    isManualCheck = true
    presentation.activate()
    service?.check()
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    automaticallyChecksForUpdates = enabled
    service?.setAutomaticChecks(enabled)
  }

  func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
    guard allowsAutomaticUpdates else { return }
    automaticallyDownloadsUpdates = enabled
    service?.setAutomaticDownloads(enabled)
  }

  func finishUpdateCycle(error: Error?) {
    if let error, UpdatePolicy.isMissingFeed(error), isManualCheck {
      message = L("还没有可用的更新信息")
    }
    isManualCheck = false
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    finishUpdateCycle(error: error)
  }

  func standardUserDriverWillShowModalAlert() {
    presentation.activate()
    if restoreWindow == nil { restoreWindow = presentation.lowerObscuringWindow() }
  }

  func standardUserDriverDidShowModalAlert() {
    restoreWindow?()
    restoreWindow = nil
  }

  func prepareToShowUpdate(_ shouldShow: Bool) {
    if shouldShow { presentation.activate() }
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    prepareToShowUpdate(handleShowingUpdate)
  }

  func presentedError(_ error: Error) -> Error? {
    guard UpdatePolicy.isMissingFeed(error) else { return error }
    guard isManualCheck else { return nil }
    return NSError(
      domain: "SUSparkleErrorDomain", code: 2001,
      userInfo: [NSLocalizedDescriptionKey: L("还没有可用的更新信息")])
  }
}

@MainActor private final class SparkleUpdateService: UpdateService {
  var stateChanged: ((UpdateServiceState) -> Void)?
  private let updater: SPUUpdater
  private var observations: Set<AnyCancellable> = []
  private var state = UpdateServiceState() {
    didSet { stateChanged?(state) }
  }

  init(bundle: Bundle, delegate: UpdateController) {
    let driver = KayoiUpdateUserDriver(hostBundle: bundle, delegate: delegate)
    driver.controller = delegate
    updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
  }

  func start() throws {
    updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
      .sink { [weak self] in self?.state.canCheck = $0 }.store(in: &observations)
    updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
      .sink { [weak self] in self?.state.automaticChecks = $0 }.store(in: &observations)
    updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main)
      .sink { [weak self] in self?.state.automaticDownloads = $0 }.store(in: &observations)
    updater.publisher(for: \.allowsAutomaticUpdates).receive(on: RunLoop.main)
      .sink { [weak self] in self?.state.allowsDownloads = $0 }.store(in: &observations)
    updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
      .sink { [weak self] in self?.state.lastCheck = $0 }.store(in: &observations)
    try updater.start()
  }
  func check() { updater.checkForUpdates() }
  func setAutomaticChecks(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled }
  func setAutomaticDownloads(_ enabled: Bool) { updater.automaticallyDownloadsUpdates = enabled }
}

@MainActor private final class KayoiUpdateUserDriver: SPUStandardUserDriver {
  weak var controller: UpdateController?
  override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    guard let presented = controller?.presentedError(error) else {
      acknowledgement()
      return
    }
    super.showUpdaterError(presented, acknowledgement: acknowledgement)
  }
}
