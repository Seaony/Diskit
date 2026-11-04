import Core
import Testing

@Test func helpCoversEverySelectableConnectionTypeWithoutDuplicateWebDAV() {
  let covered = Set(HelpGuide.all.map(\.kind))
  #expect(covered == Set(ConnectionKind.allCases.filter { $0 != .webdavHTTPS }))
  #expect(HelpGuide.all.count == covered.count)
  #expect(Set(HelpGuide.all.map(\.group)) == Set(HelpGroup.allCases))
  for guide in HelpGuide.all {
    #expect(!guide.steps.isEmpty)
    #expect(!guide.questions.isEmpty)
    #expect(guide.capabilities.count == 4)
    #expect(Set(guide.steps.map(\.id)).count == guide.steps.count)
    #expect(Set(guide.questions.map(\.id)).count == guide.questions.count)
  }
}

@Test func helpKeepsReadOnlyAndConditionalCameraCapabilitiesAccurate() throws {
  let lanzou = try #require(HelpGuide.all.first { $0.kind == .lanzou })
  #expect(lanzou.capabilities.first { $0.id == "read" }?.availability == .supported)
  for capability in lanzou.capabilities where capability.id != "read" {
    #expect(capability.availability == .unavailable)
  }
  for kind in [ConnectionKind.cameraUSB, .ricohGR] {
    let guide = try #require(HelpGuide.all.first { $0.kind == kind })
    #expect(guide.capabilities.first { $0.id == "delete" }?.availability == .deviceDependent)
    #expect(guide.capabilities.first { $0.id == "write" }?.availability == .unavailable)
    #expect(guide.capabilities.first { $0.id == "move" }?.availability == .unavailable)
  }
  let smb = try #require(HelpGuide.all.first { $0.kind == .smb })
  #expect(smb.capabilities.allSatisfy { $0.availability == .supported })
}

@Test func helpSearchFindsServiceAliasesAndPreparationContent() throws {
  let webdav = try #require(HelpGuide.all.first { $0.kind == .webdav })
  #expect(webdav.matches(" owncloud ", title: "WebDAV"))
  #expect(webdav.matches("OpenList", title: "WebDAV"))
  let phone = try #require(HelpGuide.all.first { $0.kind == .androidUSB })
  #expect(phone.matches("Samsung", title: "Android"))
  #expect(phone.matches("USB", title: "Android"))
  #expect(phone.matches("", title: "Android"))
  #expect(!phone.matches("nonexistent-search-phrase", title: "Android"))
}
