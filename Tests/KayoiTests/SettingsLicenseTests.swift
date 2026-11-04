import Foundation
import Testing

@Test func settingsLicenseReportsMissingResource() {
  #expect(throws: SettingsLicenseError.self) { _ = try SettingsLicense.read(at: nil) }
}

@Test func settingsLicenseReadsBundledTextWithoutDiscardingContents() throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".md")
  defer { try? FileManager.default.removeItem(at: file) }
  let expected = "# 许可证\n\nCopyright\n完整正文。\n"
  try expected.write(to: file, atomically: true, encoding: .utf8)
  #expect(try SettingsLicense.read(at: file) == expected)
  #expect(SettingsLicense.notices.resourceName == "THIRD_PARTY_NOTICES")
  #expect(SettingsLicense.apache.resourceExtension == "txt")
}

@Test func licenseMetadataAndMissingBundleAreExplicit() {
  #expect(SettingsLicense.notices.id == "notices")
  #expect(SettingsLicense.apache.id == "apache")
  #expect(!SettingsLicense.notices.title.isEmpty)
  #expect(!SettingsLicense.apache.title.isEmpty)
  #expect(SettingsLicense.apache.resourceName == "Apache-2.0")
  #expect(SettingsLicense.notices.resourceExtension == "md")
  #expect(SettingsLicenseError.missingResource.errorDescription?.isEmpty == false)
  _ = SettingsLicense.notices.resourceURL(in: Bundle(for: LicenseBundleMarker.self))
}

private final class LicenseBundleMarker: NSObject {}

@Test func capabilityLabelsAndSymbolsKeepThreeDistinctStates() {
  let states: [HelpCapability.Availability] = [.supported, .unavailable, .deviceDependent]
  #expect(Set(states.map(\.title)).count == 3)
  #expect(states.map(\.symbol) == ["checkmark", "minus", "questionmark.circle"])
  let capability = HelpCapability("read", "读取", .supported)
  #expect(capability.id == "read")
  #expect(capability.title == "读取")
}
