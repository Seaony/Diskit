import Foundation
import Testing

@testable import ADB

@Test func adbFingerprintMatchesAndroidPublicKeyBytes() {
  let bytes = Data((0..<524).map { UInt8(truncatingIfNeeded: $0) })
  #expect(
    ADBIdentity.fingerprint(publicKeyData: bytes)
      == "D1:FA:AD:19:50:F5:24:BB:39:77:DB:E2:1B:39:25:0A")
}
