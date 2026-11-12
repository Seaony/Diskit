import Core
import Foundation
import Testing

@Test(arguments: [EIO, EBUSY, ENOTCONN])
func quitFailureUsesTheSharedUnderlyingReason(code: Int32) {
  let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
  #expect(QuitFailure.reason(for: failure) == HumanError.message(RemoteError.posix(code)))
}

@Test func quitFailureRecognizesNativeCocoaBusyWithoutAnUnderlyingError() {
  let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountBusyError)
  #expect(QuitFailure.reason(for: failure) == HumanError.message(failure))
  #expect(QuitFailure.reason(for: failure).contains(HumanError.posix(EBUSY)))
}

@Test func unknownQuitFailureKeepsItsCodeWithoutTheSystemJargon() {
  let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                        userInfo: [NSLocalizedDescriptionKey: "raw unknown error"])
  let reason = QuitFailure.reason(for: failure)
  #expect(reason == HumanError.ejectionDetail(failure))
  #expect(reason.contains("256"))
  #expect(failure.localizedDescription == "raw unknown error")
  #expect(!reason.contains("raw unknown error"))
}
