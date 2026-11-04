import Core
import Foundation
import Testing

@testable import CloudDrive

private actor GoogleAboutTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  let quota: String
  init(quota: String = #"{"storageQuota":{"limit":"9223372036854775807","usage":"1234567890123"}}"#)
  {
    self.quota = quota
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard request.httpMethod == "GET" else { return HTTPResponse(status: 405) }
    switch request.url?.absoluteString {
    case "https://www.googleapis.com/drive/v3/about?fields=user":
      return HTTPResponse(
        status: 200,
        body: Data(
          #"{"user":{"permissionId":"user-1","displayName":"Demo","emailAddress":"demo@example.invalid"}}"#
            .utf8))
    case "https://www.googleapis.com/drive/v3/about?fields=storageQuota":
      return HTTPResponse(status: 200, body: Data(quota.utf8))
    default:
      return HTTPResponse(status: 404)
    }
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    throw RemoteError.protocolError
  }
}

private func googleProvider(_ transport: GoogleAboutTransport) throws -> GoogleDriveProvider {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "demo", refreshToken: "demo", expiresAt: .distantFuture)), for: "demo")
  return GoogleDriveProvider(
    session: OAuthSession(
      configuration: OAuthConfiguration(
        clientID: "demo", clientSecret: "",
        authorizationURL: URL(string: "https://example.invalid/authorize")!,
        tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://demo",
        scopes: []),
      secretKey: "demo", secrets: secrets, transport: transport))
}

@Test func googleAboutUsesExactDocumentedURLAndStringQuota() async throws {
  let transport = GoogleAboutTransport()
  let provider = try googleProvider(transport)
  try await provider.connect()
  let profile = try await provider.profile()
  #expect(profile.userID == "user-1" && profile.nickname == "Demo")
  let space = try await provider.spaceInfo()
  #expect(space.total == Int64.max)
  #expect(space.used == 1_234_567_890_123)
  let requests = await transport.requests
  #expect(
    requests.compactMap(\.url?.absoluteString) == [
      "https://www.googleapis.com/drive/v3/about?fields=user",
      "https://www.googleapis.com/drive/v3/about?fields=user",
      "https://www.googleapis.com/drive/v3/about?fields=storageQuota",
    ])
  #expect(requests.allSatisfy { $0.httpBody == nil })
}

@Test(arguments: ["not-a-number", "9223372036854775808", "-1"])
func googleQuotaRejectsMalformedByteCounts(_ value: String) async throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "storageQuota": ["limit": value, "usage": "0"]
  ])
  let provider = try googleProvider(
    GoogleAboutTransport(quota: String(decoding: data, as: UTF8.self)))
  try await provider.connect()
  await #expect(throws: DecodingError.self) { _ = try await provider.spaceInfo() }
}
