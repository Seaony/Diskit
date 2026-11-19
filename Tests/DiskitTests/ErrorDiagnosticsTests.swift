import Foundation
import Testing

// 日志记完整错误链：每层的错误域、错误码和原文都在，推出被占用时带上占用者进程号
@Test func errorDiagnosticsIncludesEveryUnderlyingErrorWithItsOwnText() {
  let leaf = NSError(
    domain: NSPOSIXErrorDomain, code: Int(EIO),
    userInfo: [NSLocalizedDescriptionKey: "leaf reason"])
  let nested = NSError(
    domain: "fixture.nested", code: 7,
    userInfo: [NSUnderlyingErrorKey: leaf, NSLocalizedDescriptionKey: "nested reason",
               NSFileManagerUnmountDissentingProcessIdentifierErrorKey: NSNumber(value: 42)])
  let additional = NSError(domain: "fixture.additional", code: 11)
  let outer = NSError(
    domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
    userInfo: [NSUnderlyingErrorKey: nested, NSMultipleUnderlyingErrorsKey: [leaf, additional],
               NSLocalizedDescriptionKey: "outer reason"])

  let summary = ErrorDiagnostics.summary(outer)
  #expect(summary.contains("NSCocoaErrorDomain 256: outer reason"))
  #expect(summary.contains("fixture.nested 7: nested reason"))
  #expect(summary.contains("NSPOSIXErrorDomain 5: leaf reason"))
  #expect(summary.contains("fixture.additional 11"))
  #expect(summary.hasSuffix("dissenting_pid=42"))
}

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
  override var underlyingErrors: [Error] { [self] }
}

@Test func errorDiagnosticsStopsAtRepeatedErrorObjects() {
  let error = CyclicDiagnosticError(domain: "fixture.cycle", code: 9)
  #expect(ErrorDiagnostics.summary(error).components(separatedBy: "fixture.cycle 9").count == 2)
}
