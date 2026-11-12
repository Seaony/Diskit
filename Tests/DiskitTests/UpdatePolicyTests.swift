import Foundation
import Testing

@Test func updaterNeverStartsInDemoOrTests() {
  let app = URL(filePath: "/tmp/Diskit.app")
  #expect(!UpdatePolicy.shouldStart(isDemo: true, bundleURL: app, environment: [:]))
  #expect(
    !UpdatePolicy.shouldStart(
      isDemo: false, bundleURL: app, environment: ["XCTestConfigurationFilePath": "local"]))
  #expect(
    !UpdatePolicy.shouldStart(
      isDemo: false, bundleURL: URL(filePath: "/tmp/tests.xctest"), environment: [:]))
  #expect(UpdatePolicy.shouldStart(isDemo: false, bundleURL: app, environment: [:]))
  #expect(Data(base64Encoded: UpdatePolicy.publicKey)?.count == 32)
}

@Test func updaterRecognizesOnlyMissingFeedDownloadErrors() {
  let missing = NSError(
    domain: "SUSparkleErrorDomain", code: 2001,
    userInfo: [NSLocalizedDescriptionKey: "Not Found (404)"])
  #expect(UpdatePolicy.isMissingFeed(missing))
  #expect(
    UpdatePolicy.isMissingFeed(
      NSError(domain: "outer", code: 1, userInfo: [NSUnderlyingErrorKey: missing])))
  #expect(
    !UpdatePolicy.isMissingFeed(
      NSError(
        domain: "SUSparkleErrorDomain", code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "Failed (500)"])))
  #expect(
    !UpdatePolicy.isMissingFeed(
      NSError(
        domain: "SUSparkleErrorDomain", code: 3001,
        userInfo: [NSLocalizedDescriptionKey: "Signature invalid (404)"])))
  #expect(
    !UpdatePolicy.isMissingFeed(
      NSError(domain: "other", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Not Found (404)"])
    ))
}
