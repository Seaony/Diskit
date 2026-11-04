import Core
import Foundation
import Testing

@testable import ADB

@Test func adbPairingErrorsBridgeToPOSIX() {
  let cases: [(PairingError, Int32)] = [
    (.invalidCode, EINVAL), (.wrongCode, EACCES), (.invalidPacket, EIO),
  ]
  for (error, code) in cases {
    let bridged = error as NSError
    #expect(bridged.domain == NSPOSIXErrorDomain)
    #expect(bridged.code == Int(code))
    #expect(bridged.localizedDescription == error.errorDescription)
  }
}

@Test func adbStatConvertsLinuxErrnoBeforeBridging() throws {
  let cases: [(UInt32, Int32)] = [
    (2, ENOENT), (11, EAGAIN), (13, EACCES), (35, EDEADLK), (36, ENAMETOOLONG),
    (38, ENOSYS), (39, ENOTEMPTY), (40, ELOOP), (75, EOVERFLOW),
    (95, EOPNOTSUPP), (104, ECONNRESET), (110, ETIMEDOUT), (122, EDQUOT),
    (125, ECANCELED), (UInt32.max, EIO),
  ]
  for (linuxCode, expected) in cases {
    var packet = Data()
    packet.appendLE(ADBSync.id("STA2"))
    packet.appendLE(linuxCode)
    do {
      _ = try ADBSync.decodeStat(packet, path: RemotePath("/file"), v2: true)
      Issue.record("远端错误必须抛出")
    } catch {
      let bridged = error as NSError
      #expect(bridged.domain == NSPOSIXErrorDomain)
      #expect(bridged.code == Int(expected))
    }
  }
}
