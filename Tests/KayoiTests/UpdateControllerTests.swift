import Foundation
import Testing

@MainActor private final class FakeUpdateService: UpdateService {
  var stateChanged: ((UpdateServiceState) -> Void)?
  var state = UpdateServiceState(canCheck: true, allowsDownloads: true)
  var startError: Error?
  var starts = 0
  var checks = 0
  var automaticChecks: [Bool] = []
  var automaticDownloads: [Bool] = []
  func start() throws {
    starts += 1
    if let startError { throw startError }
    stateChanged?(state)
  }
  func check() { checks += 1 }
  func setAutomaticChecks(_ enabled: Bool) { automaticChecks.append(enabled) }
  func setAutomaticDownloads(_ enabled: Bool) { automaticDownloads.append(enabled) }
  func publish(_ state: UpdateServiceState) {
    self.state = state
    stateChanged?(state)
  }
}

private func updateTestBundle(valid: Bool = true) throws -> (Bundle, URL) {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".app")
  try FileManager.default.createDirectory(
    at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
  let info: [String: String] = [
    "CFBundleIdentifier": "local.kayoi.update-tests.\(UUID().uuidString)",
    "CFBundlePackageType": "APPL",
    "SUFeedURL": valid ? UpdatePolicy.feedURL.absoluteString : "http://invalid.local/feed",
    "SUPublicEDKey": UpdatePolicy.publicKey,
  ]
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: url.appendingPathComponent("Contents/Info.plist"))
  return (try #require(Bundle(url: url)), url)
}

private func missingUpdateFeed() -> NSError {
  NSError(
    domain: "SUSparkleErrorDomain", code: 2001,
    userInfo: [NSLocalizedDescriptionKey: "Not Found (404)"])
}

@MainActor @Test func updateDemoAndTestHostsNeverConstructService() {
  var constructions = 0
  let demo = UpdateController(
    isDemo: true, environment: [:],
    serviceFactory: { _, _ in
      constructions += 1
      return FakeUpdateService()
    })
  demo.setAutomaticallyChecksForUpdates(false)
  demo.setAutomaticallyDownloadsUpdates(true)
  demo.checkForUpdates()
  #expect(constructions == 0)
  #expect(!demo.automaticallyChecksForUpdates && demo.automaticallyDownloadsUpdates)
  #expect(demo.lastUpdateCheckDate != nil && demo.message != nil)
  let disabled = UpdateController(
    isDemo: false, environment: ["SWIFT_TESTING_ENABLED": "1"],
    serviceFactory: { _, _ in
      constructions += 1
      return FakeUpdateService()
    })
  disabled.checkForUpdates()
  disabled.setAutomaticallyDownloadsUpdates(true)
  #expect(!disabled.canCheckForUpdates && !disabled.automaticallyDownloadsUpdates)
  #expect(constructions == 0)
}

@MainActor @Test func invalidUpdateConfigurationDoesNotConstructService() throws {
  let (bundle, url) = try updateTestBundle(valid: false)
  defer { try? FileManager.default.removeItem(at: url) }
  var constructions = 0
  let controller = UpdateController(
    isDemo: false, bundle: bundle, environment: [:],
    serviceFactory: { _, _ in
      constructions += 1
      return FakeUpdateService()
    })
  #expect(constructions == 0)
  #expect(controller.message != nil && !controller.canCheckForUpdates)
}

@MainActor @Test func updaterPublishesStateAndPersistsOnlyAllowedSettings() throws {
  let (bundle, url) = try updateTestBundle()
  defer { try? FileManager.default.removeItem(at: url) }
  let service = FakeUpdateService()
  var activations = 0
  let controller = UpdateController(
    isDemo: false, bundle: bundle, environment: [:],
    presentation: UpdatePresentation(activate: { activations += 1 }, lowerObscuringWindow: { nil }),
    serviceFactory: { _, _ in service })
  #expect(service.starts == 1 && controller.canCheckForUpdates)
  controller.setAutomaticallyChecksForUpdates(false)
  controller.setAutomaticallyDownloadsUpdates(true)
  #expect(service.automaticChecks == [false] && service.automaticDownloads == [true])
  let date = Date(timeIntervalSince1970: 1234)
  service.publish(
    UpdateServiceState(
      canCheck: false, automaticChecks: false,
      automaticDownloads: false, allowsDownloads: false, lastCheck: date))
  controller.checkForUpdates()
  controller.setAutomaticallyDownloadsUpdates(true)
  #expect(service.checks == 0 && activations == 0)
  #expect(service.automaticDownloads == [true])
  #expect(controller.lastUpdateCheckDate == date && !controller.allowsAutomaticUpdates)
  #expect(!controller.automaticallyChecksForUpdates && !controller.automaticallyDownloadsUpdates)
}

@MainActor @Test func updaterMissingFeedIsSilentInBackgroundAndRecoversOnNextManualCheck() throws {
  let (bundle, url) = try updateTestBundle()
  defer { try? FileManager.default.removeItem(at: url) }
  let service = FakeUpdateService()
  var activations = 0
  let controller = UpdateController(
    isDemo: false, bundle: bundle, environment: [:],
    presentation: UpdatePresentation(activate: { activations += 1 }, lowerObscuringWindow: { nil }),
    serviceFactory: { _, _ in service })
  let missing = missingUpdateFeed()
  #expect(controller.presentedError(missing) == nil)
  controller.finishUpdateCycle(error: missing)
  #expect(controller.message == nil)
  let signature = NSError(domain: "SUSparkleErrorDomain", code: 3001)
  #expect((controller.presentedError(signature) as NSError?) === signature)
  controller.checkForUpdates()
  #expect(controller.isManualCheck && activations == 1 && service.checks == 1)
  #expect(controller.presentedError(missing)?.localizedDescription != missing.localizedDescription)
  controller.finishUpdateCycle(error: missing)
  #expect(!controller.isManualCheck && controller.message != nil)
  controller.checkForUpdates()
  #expect(controller.message == nil && service.checks == 2)
  controller.finishUpdateCycle(error: nil)
  #expect(!controller.isManualCheck && controller.message == nil)
}

@MainActor @Test func updaterStartFailureIsVisibleAndWindowLevelRestoresExactlyOnce() throws {
  let (bundle, url) = try updateTestBundle()
  defer { try? FileManager.default.removeItem(at: url) }
  let service = FakeUpdateService()
  service.startError = NSError(
    domain: "local.update", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "local start failure"])
  var activations = 0
  var lowerings = 0
  var restorations = 0
  let controller = UpdateController(
    isDemo: false, bundle: bundle, environment: [:],
    presentation: UpdatePresentation(
      activate: { activations += 1 },
      lowerObscuringWindow: {
        lowerings += 1
        return { restorations += 1 }
      }), serviceFactory: { _, _ in service })
  #expect(controller.message != nil && service.starts == 1)
  controller.standardUserDriverWillShowModalAlert()
  controller.standardUserDriverWillShowModalAlert()
  #expect(lowerings == 1)
  controller.standardUserDriverDidShowModalAlert()
  controller.standardUserDriverDidShowModalAlert()
  #expect(restorations == 1)
  controller.prepareToShowUpdate(false)
  #expect(activations == 2)
  controller.prepareToShowUpdate(true)
  #expect(activations == 3)
  service.publish(UpdateServiceState(canCheck: true, allowsDownloads: true))
  controller.checkForUpdates()
  #expect(controller.message == nil && service.checks == 1)
}
