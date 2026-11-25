import Foundation
import Testing
@testable import Core

@Test func usbTimeoutAdviceMatchesTheDeviceInsteadOfNetwork() {
  #expect(HumanError.remote(.posix(ETIMEDOUT), kind: .androidUSB) == L("连接超时，请检查 USB 线缆并解锁手机后重试"))
  #expect(HumanError.remote(.posix(ETIMEDOUT), kind: .cameraUSB) == L("连接超时，请检查 USB 线缆并打开相机后重试"))
  for kind: ConnectionKind in [.androidWiFi, .smb, .quark] {
    #expect(HumanError.remote(.posix(ETIMEDOUT), kind: kind) == L("连接超时，请检查网络后重试"))
  }
}

@Test func timeoutDetailsKeepTheCodeAndDeviceAdvice() {
  let expected = L("连接超时，请检查 USB 线缆并打开相机后重试") + " (errno \(ETIMEDOUT))"
  #expect(HumanError.detail(RemoteError.posix(ETIMEDOUT), kind: .cameraUSB) == expected)
  #expect(HumanError.detail(POSIXError(.ETIMEDOUT), kind: .cameraUSB) == expected)
}
