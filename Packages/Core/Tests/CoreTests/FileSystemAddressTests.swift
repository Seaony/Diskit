import Foundation
import Testing

@testable import Core

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
    "kayoi-quark://\(id)", "kayoi-adb://user:password@\(id)", "kayoi-adb://\(id):123",
    "kayoi-adb://\(id)/path", "kayoi-adb://\(id)?token=x", "kayoi-adb://\(id)#fragment",
  ] {
    #expect(throws: (any Error).self) {
      try FileSystemAddress.connection(for: URL(string: address)!, in: [connection])
    }
  }
}
