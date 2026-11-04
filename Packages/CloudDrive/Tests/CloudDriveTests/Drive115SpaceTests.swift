import Core
import Foundation
import Testing

@testable import CloudDrive

private struct Drive115SpaceTransport: HTTPTransport {
  let space: String
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.host == "proapi.115.com", request.url?.path == "/open/user/info" else {
      return HTTPResponse(status: 404)
    }
    let json = #"{"state":true,"data":{"user_id":1,"user_name":"local","rt_space_info":\#(space)}}"#
    return HTTPResponse(status: 200, body: Data(json.utf8))
  }
}

@Test func drive115CapacityPreservesMissingFields() async throws {
  let cases: [(String, SpaceInfo)] = [
    ("null", SpaceInfo(total: nil, used: nil)),
    ("{}", SpaceInfo(total: nil, used: nil)),
    (#"{"all_total":{"size":100}}"#, SpaceInfo(total: 100, used: nil)),
    (#"{"all_use":{"size":50}}"#, SpaceInfo(total: nil, used: 50)),
    (#"{"all_total":{"size":0},"all_use":{"size":0}}"#, SpaceInfo(total: 0, used: 0)),
  ]
  for (json, expected) in cases {
    let secrets = MemorySecretStore()
    try secrets.write(
      JSONEncoder().encode(
        OAuthToken(accessToken: "local", refreshToken: "local", expiresAt: .distantFuture)),
      for: "account")
    let transport = Drive115SpaceTransport(space: json)
    let configuration = OAuthConfiguration(
      clientID: "local", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/auth")!,
      tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://test",
      scopes: [])
    let session = OAuthSession(
      configuration: configuration, secretKey: "account", secrets: secrets, transport: transport)
    let provider = Drive115Provider(session: session, transport: transport)
    try await provider.connect()
    #expect(try await provider.spaceInfo() == expected)
  }
}
