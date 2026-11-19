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
        return failure(error)
      }
      return .posix(code)
    }
    guard error.domain == ICErrorDomain else { return failure(error) }

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
    case ICLegacyReturn.Code.deviceUnsupportedErr.rawValue:
      return .posix(ENOTSUP)
    case ICReturn.Code.deleteFilesCanceled.rawValue,
      ICReturn.Code.downloadCanceled.rawValue:
      return .posix(ECANCELED)
    default:
      return failure(error)
    }
  }

  // 没有更贴切的 errno：Finder 仍拿到 EIO，界面上写出系统原话、错误域和错误码
  static func failure(_ error: NSError) -> RemoteError {
    // 错误码按原样拼成文字，免得按地区格式化成 -21,349
    let code = String(error.code)
    guard error.domain == ICErrorDomain else {
      return .failed(EIO, LF("系统报错：%@（%@ %@）", error.localizedDescription, error.domain, code))
    }
    let reason = imageCaptureReason(error.code) ?? error.localizedDescription
    return .failed(EIO, LF("ImageCapture 报错：%@（%@ %@）", reason, error.domain, code))
  }

  // ImageCapture 自带的说明多是「操作无法完成」，常见错误码按头文件注释写成人话
  static func imageCaptureReason(_ code: Int) -> String? {
    switch code {
    case ICLegacyReturn.Code.communicationErr.rawValue: L("和相机通信出错")
    case ICLegacyReturn.Code.deviceNotOpenErr.rawValue: L("相机还没有打开")
    case ICLegacyReturn.Code.fileCorruptedErr.rawValue: L("相机上的文件已损坏")
    case ICLegacyReturn.Code.deviceMemoryAllocationErr.rawValue: L("相机无法分配内存")
    case ICLegacyReturn.Code.deviceInternalErr.rawValue: L("相机内部错误")
    case ICLegacyReturn.Code.frameworkInternalErr.rawValue: L("ImageCapture 框架内部错误")
    case ICLegacyReturn.Code.invalidSessionErr.rawValue: L("相机会话已失效")
    case ICReturn.Code.sessionNotOpened.rawValue: L("相机会话还没打开")
    case ICReturn.Code.deviceFailedToOpenSession.rawValue: L("无法在相机上打开会话")
    case ICReturn.Code.downloadFailed.rawValue: L("从相机下载文件失败")
    case ICReturn.Code.failedToCompletePassThroughCommand.rawValue: L("相机没有完成 PTP 命令")
    case ICReturn.Code.deviceCommandGeneralFailure.rawValue: L("相机报告了一般性故障")
    case ICReturn.Code.deviceFailedToCompleteTransfer.rawValue: L("和相机的数据传输没有完成")
    case ICReturn.Code.deviceFailedToSendData.rawValue: L("相机发送数据失败")
    case ICReturnConnectionError.Code.driverExited.rawValue: L("相机驱动意外退出")
    case ICReturnConnectionError.Code.closedSessionSuddenly.rawValue: L("相机意外关闭了会话")
    case ICReturnConnectionError.Code.ejectedSuddenly.rawValue: L("相机被意外推出")
    case ICReturnConnectionError.Code.failedToOpen.rawValue: L("无法建立到相机的连接")
    case ICReturnConnectionError.Code.failedToOpenDevice.rawValue: L("无法打开相机")
    case ICReturnPTPDeviceError.Code.failedToSendCommand.rawValue: L("PTP 命令发送失败")
    case ICReturnObjectError.Code.codeObjectCouldNotBeRead.rawValue: L("相机上的文件读不出来")
    case ICReturnObjectError.Code.codeObjectDataEmpty.rawValue: L("相机返回的文件数据为空")
    default: nil
    }
  }
}
