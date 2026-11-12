import Foundation
import Testing
@testable import Core

@Test(arguments: [EIO, EBUSY, ENOTCONN])
func nativeErrorWrappersUseTheSameHumanReason(code: Int32) {
  let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                           userInfo: [NSLocalizedDescriptionKey: "raw error"])
  let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                       userInfo: [NSUnderlyingErrorKey: underlying])
  let expected = HumanError.posix(code)
  #expect(HumanError.message(wrapped) == expected)
  #expect(HumanError.detail(wrapped) == "\(expected) (errno \(code))")
  #expect(HumanError.detail(wrapped, kind: .androidUSB) == HumanError.detail(wrapped))
  #expect(HumanError.ejectionDetail(wrapped) == HumanError.message(wrapped))
  #expect(!HumanError.ejectionDetail(wrapped).contains("raw error"))
}

@Test func ioFailureDoesNotClaimTheConnectionWasLost() {
  let expected = L("读写这个位置时出错")
  #expect(RemoteError.posix(EIO).localizedDescription == expected)
  #expect(HumanError.message(POSIXError(.EIO)) == expected)
  #expect(HumanError.message(ConnectionError.system(EIO)) == expected)
  #expect(HumanError.message(RemoteError.protocolError) == L("服务返回了无法识别的数据"))
  #expect(HumanError.ejectionDetail(RemoteError.protocolError) == L("服务返回了无法识别的数据"))
}

@Test func confirmedDisconnectsHaveOneHumanReason() {
  let expected = L("连接已断开，读不到这个位置")
  #expect(RemoteError.notConnected.localizedDescription == expected)
  for code in [ENODEV, ENXIO, ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ENETDOWN,
               ENETRESET, ENETUNREACH] {
    #expect(HumanError.message(RemoteError.posix(code)) == expected)
  }
  for code: URLError.Code in [.networkConnectionLost, .notConnectedToInternet] {
    #expect(HumanError.message(URLError(code)) == expected)
  }
}

@Test func occupiedAndInternalWorkRemainDistinct() {
  let expected = L("还有程序在使用这个位置")
  #expect(RemoteError.occupied.localizedDescription == expected)
  #expect(HumanError.remote(.occupied, kind: .androidUSB) == expected)
  #expect(HumanError.message(ConnectionError.system(EBUSY)) == expected)
  #expect(HumanError.message(ConnectionError.busy) == L("连接正在处理，请稍后重试"))
}

@Test func nativeCocoaUnmountBusyNeedsNoUnderlyingError() {
  let error = NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountBusyError,
                      userInfo: [NSLocalizedDescriptionKey: "raw busy error"])
  let expected = L("还有程序在使用这个位置")
  #expect(HumanError.message(error) == expected)
  #expect(HumanError.detail(error) == "\(expected) (NSCocoaErrorDomain 769)")
  #expect(HumanError.ejectionDetail(error) == HumanError.message(error))
}

private struct ActionableServiceFailure: Error, LocalizedError {
  var errorDescription: String? { "Sign in to the service again." }
}

@Test func unrelatedServiceAdviceRemainsVisible() {
  let failure = ActionableServiceFailure()
  #expect(HumanError.message(failure) == failure.localizedDescription)
  #expect(HumanError.detail(failure) == failure.localizedDescription)
  #expect(HumanError.message(failure, fallback: L("操作没有完成，请稍后重试")) == L("操作没有完成，请稍后重试"))
}

@Test func unknownEjectionFallbackDoesNotLeakIntoOtherOperations() {
  let unknown = NSError(domain: "fixture.unknown", code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "private unknown error"])
  #expect(HumanError.message(unknown) == unknown.localizedDescription)
  #expect(!HumanError.message(unknown).contains(L("推出失败")))
  #expect(HumanError.ejectionDetail(unknown) == LF("推出失败（错误码 %@）", "99"))
  let posix = RemoteError.posix(999)
  #expect(HumanError.detail(posix) == "\(L("操作没有完成，请稍后重试")) (errno 999)")
  #expect(HumanError.ejectionDetail(posix) == LF("推出失败（错误码 %@）", "999"))
  #expect(HumanError.ejectionDetail(ConnectionError.system(-123)) == LF("推出失败（错误码 %@）", "-123"))
}

private final class CyclicHumanError: NSError, @unchecked Sendable {
  override var underlyingErrors: [Error] { [self] }
}

@Test func humanErrorMappingStopsAtCyclesAndFindsKnownUnderlyingErrors() {
  let cycle = CyclicHumanError(domain: "fixture.cycle", code: 9)
  #expect(HumanError.ejectionDetail(cycle) == LF("推出失败（错误码 %@）", "9"))
  let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                        userInfo: [NSMultipleUnderlyingErrorsKey: [cycle, POSIXError(.EBUSY)]])
  #expect(HumanError.message(wrapper) == L("还有程序在使用这个位置"))
}
