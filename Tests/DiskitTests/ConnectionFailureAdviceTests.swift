import Core
import Testing

@Test func deviceFailureAdviceDoesNotSuggestNetworkOrAccountLogin() {
  for kind in [ConnectionKind.androidUSB, .cameraUSB, .ricohGR] {
    let advice = ConnectionFailureAdvice.text(for: kind)
    #expect(!advice.contains("网络"))
    #expect(!advice.contains("登录"))
    #expect(advice.contains("USB") || advice.contains("数据线"))
  }
}

@Test func wirelessFailureAdviceExplainsPairingAndSameNetwork() {
  let advice = ConnectionFailureAdvice.text(for: .androidWiFi)
  #expect(advice.contains("Wi-Fi"))
  #expect(advice.contains("配对"))
}

@Test func serverFailureAdviceReusesProtocolSpecificPreparation() {
  for kind in [ConnectionKind.smb, .webdav, .webdavHTTPS, .nfs, .s3, .cloudflareR2, .lanzou] {
    #expect(
      ConnectionFailureAdvice.text(for: kind)
        == EditorPreparation.plainSteps(for: kind).joined(separator: "\n"))
  }
  for kind in ConnectionKind.allCases { #expect(!ConnectionFailureAdvice.text(for: kind).isEmpty) }
}

// 连接指南里的样式标记不能漏到只显示文字的地方
@Test func preparationPlainStepsDropMarkup() {
  for kind in ConnectionKind.allCases {
    for step in EditorPreparation.plainSteps(for: kind) {
      #expect(!step.contains("**") && !step.contains("~~") && !step.contains("*"))
    }
  }
}
