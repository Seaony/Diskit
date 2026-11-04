import Foundation
import Testing
@testable import Core

@Test func pseudoLocalizationExpandsVisibleTextWithoutDroppingContent() {
  #expect(KayoiLocalization.expanded("Hello") == "［Hello··］")
  #expect(KayoiLocalization.expanded("") == "")
  #expect(KayoiLocalization.expanded("位置 %@").contains("位置 %@"))
}

@Test func localizationFallsBackToKeyAndFormatsArguments() {
  #expect(KayoiLocalization.text("Missing test key", bundle: .main) == "Missing test key")
  #expect(KayoiLocalization.text("%@ / %lld", bundle: .main, arguments: ["Disk", Int64(3)]) == "Disk / 3")
}

@Test func packageTranslationIsAvailableWithoutMainApplicationBundle() throws {
  let path = try #require(Bundle.module.path(forResource: "en", ofType: "lproj"))
  let english = try #require(Bundle(path: path))
  let translated = KayoiLocalization.text("连接超时，请检查主机地址和网络", bundle: english)
  #expect(translated != "连接超时，请检查主机地址和网络")
  #expect(!translated.isEmpty)
}
