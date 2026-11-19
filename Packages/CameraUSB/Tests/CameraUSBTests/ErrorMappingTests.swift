import Core
import Foundation
import ImageCaptureCore
import Testing

@testable import CameraUSB

@Test func errorMapperPreservesPOSIXAndMapsCameraFailures() {
  #expect(
    CameraUSBErrorMapper.map(RemoteError.posix(ENOENT)) == RemoteError.posix(ENOENT))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .posix(EACCES))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(
        domain: ICErrorDomain,
        code: ICReturn.Code.communicationTimedOut.rawValue)) == .posix(ETIMEDOUT))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(
        domain: ICErrorDomain,
        code: ICReturnConnectionError.Code.closedSessionSuddenly.rawValue))
      == .failed(
        EIO,
        LF(
          "ImageCapture 报错：%@（%@ %@）", L("相机意外关闭了会话"), ICErrorDomain,
          String(ICReturnConnectionError.Code.closedSessionSuddenly.rawValue))))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(
        domain: ICErrorDomain,
        code: ICLegacyReturn.Code.deviceNotFoundErr.rawValue)) == .posix(ENODEV))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(
        domain: ICErrorDomain,
        code: ICReturnObjectError.Code.codeObjectDoesNotExist.rawValue)) == .posix(ENOENT))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(
        domain: ICErrorDomain,
        code: ICReturnConnectionError.Code.notAuthorizedToOpenDevice.rawValue)) == .posix(EACCES))
  #expect(
    CameraUSBErrorMapper.map(
      NSError(domain: ICErrorDomain, code: ICReturn.Code.deleteFilesFailed.rawValue))
      == .posix(EACCES))
}

@Test func errorMapperUsesIOForUnknownAndCancellationForCancelledWork() {
  // 不认识的错误保留 EIO，同时带上系统原话、错误域和错误码
  let unknown = NSError(domain: "Unknown", code: 1)
  #expect(
    CameraUSBErrorMapper.map(unknown)
      == .failed(EIO, LF("系统报错：%@（%@ %@）", unknown.localizedDescription, "Unknown", "1")))
  #expect(CameraUSBErrorMapper.map(CancellationError()) == .posix(ECANCELED))
}

@Test func cameraErrorMappingCoversMalformedPOSIXAndNativeCodes() {
  for code in [0, -1, Int.max] {
    let error = NSError(domain: NSPOSIXErrorDomain, code: code)
    #expect(
      CameraUSBErrorMapper.map(error)
        == .failed(
          EIO,
          LF("系统报错：%@（%@ %@）", error.localizedDescription, NSPOSIXErrorDomain, String(code))))
  }
  let codes: [(Int, Int32)] = [
    (ICReturn.Code.invalidParam.rawValue, EINVAL),
    (ICReturnObjectError.Code.codeObjectDataRequestTooLarge.rawValue, EFBIG),
    (ICReturnConnectionError.Code.sessionAlreadyOpen.rawValue, EBUSY),
    (ICLegacyReturn.Code.deviceUnsupportedErr.rawValue, ENOTSUP),
    (ICReturn.Code.deleteFilesCanceled.rawValue, ECANCELED),
  ]
  for (code, expected) in codes {
    #expect(
      CameraUSBErrorMapper.map(NSError(domain: ICErrorDomain, code: code)) == .posix(expected))
  }
  let unknown = NSError(domain: ICErrorDomain, code: -999999)
  #expect(
    CameraUSBErrorMapper.map(unknown)
      == .failed(
        EIO, LF("ImageCapture 报错：%@（%@ %@）", unknown.localizedDescription, ICErrorDomain, "-999999")))
}
