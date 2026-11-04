import Core
import CoreTestSupport
import Foundation
import Testing

@testable import S3Drive

@Test(arguments: ["http://nas.local:9000", "https://nas.local:9000"])
func s3CustomMinIOEndpointPreservesExplicitProtocol(endpoint: String) async throws {
  let transport = ScriptedHTTPTransport([HTTPResponse(status: 200)])
  let config = try S3ServicePreset.minIO.configuration(
    bucket: "photos", accessKey: "local", secretKey: "local",
    customEndpoint: URL(string: endpoint)!)
  let provider = S3Provider(configuration: config, transport: transport)
  try await provider.connect()
  _ = try await provider.spaceInfo()
  let request = try #require(transport.requests.withLock { $0.first })
  #expect(request.url?.absoluteString == endpoint + "/photos")
  #expect(request.value(forHTTPHeaderField: "Host") == "nas.local:9000")
  #expect(
    request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
}

@Test(arguments: ["ftp://nas.local", "file:///tmp/bucket", "https://user:password@nas.local"])
func s3RejectsUnsupportedOrEmbeddedCredentialEndpoints(endpoint: String) async throws {
  let transport = ScriptedHTTPTransport([])
  let provider = S3Provider(
    configuration: S3Configuration(
      endpoint: URL(string: endpoint)!, region: "test", bucket: "photos", accessKey: "local",
      secretKey: "local"), transport: transport)
  await #expect(throws: RemoteError.posix(EINVAL)) { try await provider.connect() }
  #expect(transport.requests.withLock { $0.isEmpty })
}

@Test(arguments: [
  "http://nas", "http://nas.local:9000", "http://10.1.2.3", "http://172.16.1.2",
  "http://172.31.1.2", "http://192.168.1.2", "http://127.0.0.1", "http://169.254.1.2",
  "http://[::1]", "http://[fd00::123]", "http://[fe80::123]", "https://s3.example.com",
])
func s3EndpointPolicyAllowsLocalHTTPAndRemoteHTTPS(endpoint: String) {
  #expect(S3EndpointPolicy.allows(URL(string: endpoint)!))
}

@Test(arguments: [
  "http://example.com", "http://8.8.8.8", "http://172.15.1.2", "http://172.32.1.2",
  "http://192.169.1.2", "http://169.253.1.2", "http://[2001:db8::1]", "http://2130706433",
  "ftp://nas.local", "https://user:password@nas.local",
])
func s3EndpointPolicyRejectsRemoteHTTPAndUnsafeURLs(endpoint: String) {
  #expect(!S3EndpointPolicy.allows(URL(string: endpoint)!))
}
