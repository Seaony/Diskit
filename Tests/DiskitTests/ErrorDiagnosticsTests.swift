import Foundation
import Testing

@Test func errorDiagnosticsIncludesEveryUnderlyingErrorWithoutPrivateUserInfo() {
  let secret = "private-token-should-not-appear"
  let leaf = NSError(
    domain: NSPOSIXErrorDomain, code: Int(EIO),
    userInfo: [NSLocalizedDescriptionKey: secret])
  let nested = NSError(
    domain: "fixture.nested", code: 7,
    userInfo: [NSUnderlyingErrorKey: leaf,
               NSFileManagerUnmountDissentingProcessIdentifierErrorKey: NSNumber(value: 42)])
  let additional = NSError(domain: "fixture.additional", code: 11)
  let outer = NSError(
    domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
    userInfo: [NSUnderlyingErrorKey: nested, NSMultipleUnderlyingErrorsKey: [leaf, additional],
               NSLocalizedDescriptionKey: secret, NSLocalizedFailureReasonErrorKey: secret,
               NSURLErrorKey: URL(string: "https://user:password@fixture.invalid/private")!,
               "credential": secret])

  let summary = ErrorDiagnostics.summary(outer)
  #expect(summary == "domain=NSCocoaErrorDomain code=256; domain=fixture.nested code=7 dissenting_pid=42; domain=NSPOSIXErrorDomain code=5; domain=fixture.additional code=11")
  #expect(outer.userInfo["credential"] as? String == secret)
  #expect(!summary.contains(secret))
  #expect(!summary.contains("password"))
  #expect(!summary.contains("fixture.invalid"))
}

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
  override var underlyingErrors: [Error] { [self] }
}

@Test func errorDiagnosticsStopsAtRepeatedErrorObjects() {
  let error = CyclicDiagnosticError(domain: "fixture.cycle", code: 9)
  #expect(ErrorDiagnostics.summary(error) == "domain=fixture.cycle code=9")
}
