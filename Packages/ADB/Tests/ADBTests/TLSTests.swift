import Core
import Foundation
import Security
import Synchronization
import Testing

@testable import ADB

private final class TLSSecrets: SecretStore, Sendable {
  let values = Mutex<[String: Data]>([:])
  func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
  func write(_ data: Data, for key: String) throws { values.withLock { $0[key] = data } }
  func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

@Test func certificateUsesExistingRSAKeyAndValidSystemSignature() throws {
  let store = TLSSecrets()
  let source = ADBIdentity(store: store)
  let identity = try #require(sec_identity_copy_ref(source.tlsIdentity())).takeRetainedValue()
  var certificate: SecCertificate?
  #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
  let cert = try #require(certificate)
  let key = try #require(SecCertificateCopyKey(cert))
  let der = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
  #expect(try ADBIdentity.encode(publicDER: der) == source.publicKeyData())
  var trust: SecTrust?
  #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
  let evaluation = try #require(trust)
  SecTrustSetAnchorCertificates(evaluation, [cert] as CFArray)
  SecTrustSetNetworkFetchAllowed(evaluation, false)
  #expect(SecTrustEvaluateWithError(evaluation, nil))
}

@Test func startTLSOnlyAcceptsExpectedADBHandshake() throws {
  let valid = ADBMessage(.startTLS, 0x0100_0000).encoded()
  #expect(try ADBStartTLS.response(to: valid) == valid)
  #expect(throws: RemoteError.protocolError) {
    try ADBStartTLS.response(to: ADBMessage(.connect, 0x0100_0001).encoded())
  }
  #expect(throws: RemoteError.protocolError) {
    try ADBStartTLS.response(to: ADBMessage(.startTLS, 42).encoded())
  }
  #expect(throws: RemoteError.protocolError) { try ADBStartTLS.response(to: valid.dropLast()) }
}
