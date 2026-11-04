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
        code: ICReturnConnectionError.Code.closedSessionSuddenly.rawValue)) == .posix(EIO))
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
  #expect(
    CameraUSBErrorMapper.map(NSError(domain: "Unknown", code: 1)) == .posix(EIO))
  #expect(CameraUSBErrorMapper.map(CancellationError()) == .posix(ECANCELED))
}

@Test func cameraErrorMappingCoversMalformedPOSIXAndNativeCodes() {
  for code in [0, -1, Int.max] {
    #expect(
      CameraUSBErrorMapper.map(NSError(domain: NSPOSIXErrorDomain, code: code)) == .posix(EIO))
  }
  let codes: [(Int, Int32)] = [
    (ICReturn.Code.invalidParam.rawValue, EINVAL),
    (ICReturnObjectError.Code.codeObjectDataRequestTooLarge.rawValue, EFBIG),
    (ICReturnConnectionError.Code.sessionAlreadyOpen.rawValue, EBUSY),
    (ICLegacyReturn.Code.deviceUnsupportedErr.rawValue, ENOTSUP),
    (ICReturn.Code.deleteFilesCanceled.rawValue, ECANCELED),
    (-999999, EIO),
  ]
  for (code, expected) in codes {
    #expect(
      CameraUSBErrorMapper.map(NSError(domain: ICErrorDomain, code: code)) == .posix(expected))
  }
}
