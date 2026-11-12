import Foundation
import Testing

@testable import Core

@Test func fileSystemSchemeDeclarationsFitSystemLengthLimitAndMatchCore() throws {
  let schemes = FileSystemAddress.supportedSchemes
  #expect(schemes.count == 23)
  let oversized = schemes.filter { $0.utf8.count >= 16 }
  #expect(oversized == [])

  let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let infoURL = package.appending(path: "../../FSExtension/Info.plist").standardizedFileURL
  let info = try #require(
    try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
      as? [String: Any])
  let attributes = try #require(info["EXAppExtensionAttributes"] as? [String: Any])
  let declared = try #require(attributes["FSSupportedSchemes"] as? [String])
  #expect(Set(declared) == Set(schemes))
}

@Test(arguments: ConnectionKind.allCases)
func fileSystemAddressesResolveTheSavedConnection(kind: ConnectionKind) throws {
  let connection = Connection(kind: kind, name: "位置")
  if kind.fileSystemScheme == nil {
    #expect(throws: (any Error).self) { try FileSystemAddress.url(for: connection) }
  } else {
    let url = try FileSystemAddress.url(for: connection)
    #expect(try FileSystemAddress.connection(for: url, in: [connection]) == connection)
    #expect(throws: (any Error).self) { try FileSystemAddress.connection(for: url, in: []) }
  }
}

@Test func fileSystemAddressCannotSelectAnotherKindOrCarryCredentials() throws {
  let connection = Connection(kind: .androidUSB)
  let id = connection.id.uuidString
  for address in [
    "diskit-quark://\(id)", "diskit-adb://user:password@\(id)", "diskit-adb://\(id):123",
    "diskit-adb://\(id)/path", "diskit-adb://\(id)?token=x", "diskit-adb://\(id)#fragment",
  ] {
    #expect(throws: (any Error).self) {
      try FileSystemAddress.connection(for: URL(string: address)!, in: [connection])
    }
  }
}
