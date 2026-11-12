import Core
import Foundation
import Testing

@Test func panelOffersCancellationForBothBusyConnectionStates() {
  for state in [ConnectionState.connecting, .awaitingAuthorization] {
    #expect(PanelCopy.buttonTitle(state, kind: .androidUSB) == L("取消"))
  }
}

@Test func panelUnavailableExplanationMatchesDeviceType() {
  #expect(PanelCopy.subtitle(.unavailable, kind: .androidUSB) == L("手机未连接"))
  #expect(PanelCopy.subtitle(.unavailable, kind: .ricohGR) == L("相机未连接"))
  #expect(PanelCopy.subtitle(.unavailable, kind: .cameraUSB) == L("相机未连接"))
}

@Test func panelStateMatrixKeepsCapacityUnknownAndErrorDetail() {
  let unknown = SpaceInfo(total: nil, used: nil)
  #expect(PanelCopy.subtitle(.tested(unknown), kind: .s3) == SpaceSummary.subtitle(unknown))
  #expect(PanelCopy.subtitle(.mounted(MountedShare(url: URL(filePath: "/tmp/demo"))), kind: .smb) == L("已挂载"))
  #expect(PanelCopy.subtitle(.failed("reason"), kind: .smb).contains("reason"))
  #expect(PanelCopy.subtitle(.needsLogin, kind: .aliyunDrive) == L("登录已过期"))
  #expect(PanelCopy.subtitle(.disconnected, kind: .smb) == L("未连接"))
  #expect(PanelCopy.subtitle(.ejecting, kind: .smb) == L("正在推出…"))
  #expect(PanelCopy.buttonTitle(.tested(unknown), kind: .s3) == L("挂载"))
}

@Test func cardCaptionPrefersCapacityThenShortStatus() {
  let mounted = MountedShare(url: URL(filePath: "/tmp/demo"), availableBytes: 120_000_000_000)
  #expect(PanelCopy.cardCaption(.mounted(mounted), kind: .smb).contains("120"))
  #expect(PanelCopy.cardCaption(.mounted(MountedShare(url: URL(filePath: "/tmp/demo"))), kind: .smb) == L("已挂载"))
  #expect(PanelCopy.cardCaption(.tested(SpaceInfo(total: nil, used: nil)), kind: .s3) == L("已连接"))
  #expect(PanelCopy.cardCaption(.failed("很长的原因"), kind: .smb) == L("出错"))
  #expect(PanelCopy.cardCaption(.awaitingAuthorization, kind: .androidUSB) == L("等待手机授权"))
  #expect(PanelCopy.cardCaption(.needsLogin, kind: .aliyunDrive) == L("登录已过期"))
}

@Test func listCaptionKeepsErrorDetail() {
  #expect(PanelCopy.listCaption(.failed("x"), kind: .smb, detail: "密码错误").contains("密码错误"))
  #expect(PanelCopy.listCaption(.disconnected, kind: .smb, detail: nil) == L("未连接"))
}
