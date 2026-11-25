import Foundation
import Testing
@testable import Core

@Test(arguments: [EIO, EBUSY, ENOTCONN])
func nativeErrorWrappersShowTheUnderlyingOriginalText(code: Int32) {
  let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                           userInfo: [NSLocalizedDescriptionKey: "raw error"])
  let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                       userInfo: [NSUnderlyingErrorKey: underlying])
  // 底层错误带了原文就显示原文，errno 附在后面
  #expect(HumanError.message(wrapped) == "raw error")
  #expect(HumanError.detail(wrapped) == "raw error (errno \(code))")
  #expect(HumanError.detail(wrapped, kind: .androidUSB) == HumanError.detail(wrapped))
  #expect(HumanError.ejectionDetail(wrapped) == HumanError.message(wrapped))
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
  #expect(HumanError.remote(.occupied, kind: .cameraUSB) == expected)
  #expect(HumanError.remote(.occupied, kind: .androidUSB).contains("Android Studio"))
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
  // 有真实原因就显示真实原因，不被笼统的兜底文字盖掉
  #expect(HumanError.message(failure, fallback: L("操作没有完成，请稍后重试")) == failure.localizedDescription)
}

@Test func unknownEjectionFallbackDoesNotLeakIntoOtherOperations() {
  let unknown = NSError(domain: "fixture.unknown", code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "private unknown error"])
  #expect(HumanError.message(unknown) == unknown.localizedDescription)
  #expect(!HumanError.message(unknown).contains(L("推出失败")))
  #expect(HumanError.ejectionDetail(unknown) == LF("推出失败：%@（错误码 %@）", "private unknown error", "99"))
  // 没有专门文案的 errno 显示系统自己的说明
  let posix = RemoteError.posix(999)
  #expect(HumanError.detail(posix) == "\(HumanError.posix(999)) (errno 999)")
  #expect(HumanError.posix(ECONNREFUSED) != L("操作没有完成，请稍后重试"))
  #expect(HumanError.ejectionDetail(posix) == LF("推出失败：%@（错误码 %@）", HumanError.posix(999), "999"))
  let system123 = ConnectionError.system(-123)
  #expect(HumanError.ejectionDetail(system123) == LF("推出失败：%@（错误码 %@）", HumanError.message(system123), "-123"))
}

private final class CyclicHumanError: NSError, @unchecked Sendable {
  override var underlyingErrors: [Error] { [self] }
}

@Test func humanErrorMappingStopsAtCyclesAndFindsKnownUnderlyingErrors() {
  let cycle = CyclicHumanError(domain: "fixture.cycle", code: 9)
  #expect(HumanError.ejectionDetail(cycle) == LF("推出失败：%@（错误码 %@）", HumanError.message(cycle), "9"))
  let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                        userInfo: [NSMultipleUnderlyingErrorsKey: [cycle, POSIXError(.EBUSY)]])
  #expect(HumanError.message(wrapper) == L("还有程序在使用这个位置"))
}

// 错误原因里的数量走复数变体，错误码按字符串原样显示，不加千位分隔符
@Test func failureReasonsFormatCountsAndCodesLiterally() {
  #expect(LF("天翼云盘的 %@ 任务有 %lld 项失败（任务号 %@）", "删除", Int64(3), "31023").contains("31023"))
  #expect(LF("天翼云盘的 %@ 任务有 %lld 项失败（任务号 %@）", "删除", Int64(3), "31023").contains("3"))
  #expect(LF("推出失败：%@（错误码 %@）", "param error", String(31023)).contains("31023"))
}

private struct OwnReasonEIO: Error, LocalizedError, CustomNSError {
  static var errorDomain: String { NSPOSIXErrorDomain }
  var errorCode: Int { Int(EIO) }
  var errorDescription: String? { "请在网页上完成验证后重试" }
}

// errno 是 EIO 的错误自带说明时显示它自己的说明，不换成“读写这个位置时出错”
@Test func posixBridgedErrorsKeepTheirOwnReason() {
  #expect(HumanError.message(OwnReasonEIO()) == "请在网页上完成验证后重试")
  let text = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "bad server response"])
  #expect(HumanError.message(text) == "bad server response")
  #expect(HumanError.message(POSIXError(.EIO)) == HumanError.posix(EIO))
}

// 扩展挂载失败的原因经共享目录传给 App：界面显示真实原因，报告带上扩展的完整报告
@Test func extensionMountFailureCarriesTheRealReason() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let connection = Connection(kind: .androidUSB, name: "Phone")
  let before = Date()
  try MountFailureRecord.save(
    RemoteError.failed(EBUSY, "phone is busy"), connection: connection, dataDirectory: directory)
  let record = try #require(
    MountFailureRecord.take(dataDirectory: directory, connectionID: connection.id, since: before))
  #expect(MountFailureRecord.take(dataDirectory: directory, connectionID: connection.id, since: before) == nil)
  let failure = ExtensionMountFailure(record: record, underlying: POSIXError(.EBUSY))
  #expect(HumanError.message(failure) == "phone is busy")
  let report = HumanError.report(failure, kind: .androidUSB)
  #expect(report.contains("Extension report:"))
  #expect(report.contains("RemoteError.failed errno 16: phone is busy"))
  #expect(report.contains("NSPOSIXErrorDomain 16"))
  // 比这次挂载更早的记录不算
  try MountFailureRecord.save(RemoteError.failed(EIO, "old"), connection: connection, dataDirectory: directory)
  #expect(MountFailureRecord.take(dataDirectory: directory, connectionID: connection.id, since: Date().addingTimeInterval(60)) == nil)
}
