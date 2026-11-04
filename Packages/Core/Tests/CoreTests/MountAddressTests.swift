import Foundation
import Testing

@testable import Core

@Test(arguments: ["smb", "SMB"])
func mountTableMatchesEncodedChineseShare(scheme: String) {
  let connection = Connection(
    kind: .smb, name: "共享", params: ["host": "nas.local", "share": "照片 共享"])
  #expect(
    SystemMountAddress.matches(
      connection: connection,
      source: "\(scheme)://NAS.LOCAL/%E7%85%A7%E7%89%87%20%E5%85%B1%E4%BA%AB", type: "smbfs"))
}

@Test(arguments: ["café", "cafe\u{301}"])
func mountTableMatchesCanonicalUnicode(name: String) throws {
  let connection = Connection(
    kind: .smb, name: "共享", params: ["host": "NAS.local", "share": "café"])
  let source = try SMBAddress.url(host: "nas.LOCAL", share: name).absoluteString
  #expect(SystemMountAddress.matches(connection: connection, source: source, type: "smbfs"))
}

@Test func mountTableDecodesExactlyOnceAndPreservesPathCase() throws {
  let connection = Connection(
    kind: .smb, name: "共享", params: ["host": "nas.local", "share": "Photos%20"])
  let source = try SMBAddress.url(host: "NAS.local", share: "Photos%20").absoluteString
  #expect(SystemMountAddress.matches(connection: connection, source: source, type: "smbfs"))
  for other in ["Photos ", "photos%20", "Photos%2520"] {
    let wrong = try SMBAddress.url(host: "nas.local", share: other).absoluteString
    #expect(!SystemMountAddress.matches(connection: connection, source: wrong, type: "smbfs"))
  }
}

@Test func mountTableMatchesWebDAVAndRawNFS() {
  let web = Connection(
    kind: .webdavHTTPS, name: "网页共享", params: ["url": "https://nas.local/caf%C3%A9"])
  #expect(
    SystemMountAddress.matches(
      connection: web, source: "HTTPS://NAS.LOCAL/cafe%CC%81/", type: "webdav"))
  let nfs = Connection(
    kind: .nfs, name: "网络共享", params: ["host": "nas.local", "path": "/照片/café%20"])
  #expect(
    SystemMountAddress.matches(connection: nfs, source: "NAS.LOCAL:/照片/cafe\u{301}%20", type: "nfs")
  )
  #expect(!SystemMountAddress.matches(connection: nfs, source: "NAS.LOCAL:/照片/café ", type: "nfs"))
  #expect(
    !SystemMountAddress.matches(
      connection: web, source: "https://other.local/caf%C3%A9", type: "webdav"))
  #expect(
    !SystemMountAddress.matches(
      connection: web, source: "https://nas.local/caf%C3%A9", type: "smbfs"))
}

@Test func mountTableMatchesUppercaseSavedScheme() {
  let connection = Connection(
    kind: .webdavHTTPS, name: "网页共享", params: ["url": "HTTPS://nas.local/dav"])
  #expect(
    SystemMountAddress.matches(
      connection: connection, source: "https://NAS.LOCAL/dav", type: "webdav"))
}
