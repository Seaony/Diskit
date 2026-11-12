import Core
import Foundation
import Testing

@testable import CloudDrive

private actor UploadRouteProbe: HTTPTransport {
  let rejection: Int
  var uploads = 0
  var calls: [String] = []
  init(rejection: Int) { self.rejection = rejection }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    calls.append("send")
    if request.url?.path == "/token" {
      return HTTPResponse(
        status: 200,
        body: Data(#"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
    }
    return HTTPResponse(status: 200)
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    calls.append("upload")
    uploads += 1
    #expect(request.httpBody == Data([1, 2, 3]))
    if uploads == 1 { return HTTPResponse(status: rejection, headers: ["Retry-After": "0"]) }
    return HTTPResponse(status: 200)
  }
}

@Test func OAuthUploadRetryKeepsTransferRoute() async throws {
  let probe = UploadRouteProbe(rejection: 401)
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture)),
    for: "test")
  let config = OAuthConfiguration(
    clientID: "local", clientSecret: "",
    authorizationURL: URL(string: "https://example.invalid/auth")!,
    tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://local",
    scopes: [])
  let session = OAuthSession(
    configuration: config, secretKey: "test", secrets: secrets, transport: probe)
  var request = URLRequest(url: URL(string: "https://example.invalid/file")!)
  request.httpMethod = "PUT"
  request.httpBody = Data([1, 2, 3])
  #expect(try await session.authorized(request, upload: true).status == 200)
  #expect(await probe.calls == ["upload", "send", "upload"])
}

@Test func rateLimitedUploadRetryKeepsTransferRoute() async throws {
  let probe = UploadRouteProbe(rejection: 429)
  var request = URLRequest(url: URL(string: "https://example.invalid/file")!)
  request.httpMethod = "PUT"
  request.httpBody = Data([1, 2, 3])
  #expect(try await CloudDriveSupport.sendWithRetry(probe, request, upload: true, retrySafe: true).status == 200)
  #expect(await probe.calls == ["upload", "upload"])
  _ = try await CloudDriveSupport.sendWithRetry(
    probe, URLRequest(url: URL(string: "https://example.invalid/metadata")!))
  #expect(await probe.calls == ["upload", "upload", "send"])
}
