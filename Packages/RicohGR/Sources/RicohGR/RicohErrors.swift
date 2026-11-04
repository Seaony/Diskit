import Core
import Foundation
import ImageCaptureCore

enum RicohErrorMapper {
  static func map(_ error: Error) -> RemoteError {
    if let error = error as? RemoteError { return error }
    if error is CancellationError { return .posix(ECANCELED) }

    let error = error as NSError
    if error.domain == NSPOSIXErrorDomain {
      guard error.code > 0, let code = Int32(exactly: error.code) else {
        return .posix(EIO)
      }
      return .posix(code)
    }
    guard error.domain == ICErrorDomain else { return .posix(EIO) }

    switch error.code {
    case ICReturn.Code.communicationTimedOut.rawValue:
      return .posix(ETIMEDOUT)
    case ICReturn.Code.invalidParam.rawValue,
      ICReturnObjectError.Code.codeObjectDataOffsetInvalid.rawValue:
      return .posix(EINVAL)
    case ICReturnObjectError.Code.codeObjectDataRequestTooLarge.rawValue:
      return .posix(EFBIG)
    case ICReturnObjectError.Code.codeObjectDoesNotExist.rawValue:
      return .posix(ENOENT)
    case ICReturnConnectionError.Code.notAuthorizedToOpenDevice.rawValue,
      ICReturnPTPDeviceError.Code.notAuthorizedToSendCommand.rawValue,
      ICReturn.Code.deviceIsPasscodeLocked.rawValue,
      ICReturn.Code.deviceNeedsCredentials.rawValue,
      ICReturn.Code.deleteFilesFailed.rawValue:
      return .posix(EACCES)
    case ICReturnConnectionError.Code.sessionAlreadyOpen.rawValue,
      ICReturn.Code.deviceIsBusyEnumerating.rawValue:
      return .posix(EBUSY)
    case ICLegacyReturn.Code.deviceNotFoundErr.rawValue:
      return .posix(ENODEV)
    case ICLegacyReturn.Code.deviceNotOpenErr.rawValue,
      ICLegacyReturn.Code.invalidSessionErr.rawValue,
      ICReturn.Code.sessionNotOpened.rawValue,
      ICReturnConnectionError.Code.closedSessionSuddenly.rawValue,
      ICReturnConnectionError.Code.ejectedSuddenly.rawValue,
      ICReturnConnectionError.Code.driverExited.rawValue:
      return .posix(EIO)
    case ICLegacyReturn.Code.deviceUnsupportedErr.rawValue:
      return .posix(ENOTSUP)
    case ICReturn.Code.deleteFilesCanceled.rawValue,
      ICReturn.Code.downloadCanceled.rawValue:
      return .posix(ECANCELED)
    default:
      return .posix(EIO)
    }
  }
}
