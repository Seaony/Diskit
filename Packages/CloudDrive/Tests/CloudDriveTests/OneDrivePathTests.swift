import Core
import Foundation
import Testing

@testable import CloudDrive

private actor OneDrivePathTransport: HTTPTransport {
  let itemURL: String
  let name: String
  private(set) var requests: [URLRequest] = []
  init(encodedName: String, name: String) {
    itemURL = "https://graph.microsoft.com/v1.0/me/drive/root:/folder/" + encodedName
    self.name = name
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    let url = request.url?.absoluteString
    if url == "https://graph.microsoft.com/v1.0/me/drive/root" { return HTTPResponse(status: 200) }
    if url == itemURL {
      return HTTPResponse(
        status: 200,
        body: try JSONSerialization.data(withJSONObject: ["id": "demo", "name": name, "size": 4]))
    }
    if url == itemURL + ":/children" {
      return HTTPResponse(status: 200, body: Data(#"{"value":[]}"#.utf8))
    }
    return HTTPResponse(status: 404)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.append(request)
    guard request.url?.absoluteString == itemURL + ":/content" else {
      throw RemoteError.posix(ENOENT)
    }
    return HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream {
        $0.yield(Data("demo".utf8))
        $0.finish()
      })
  }
}

@Test(arguments: [
  ["中文", "%E4%B8%AD%E6%96%87"], ["a b", "a%20b"], ["a+b", "a%2Bb"],
  ["a#b", "a%23b"], ["😀", "%F0%9F%98%80"], ["a%20b", "a%2520b"],
])
func oneDrivePathsEncodeEachSegmentOnce(_ sample: [String]) async throws {
  let transport = OneDrivePathTransport(encodedName: sample[1], name: sample[0])
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "demo", refreshToken: nil,
        expiresAt: .distantFuture)), for: "demo")
  let provider = OneDriveProvider(
    session: OAuthSession(
      configuration: OAuthConfiguration(
        clientID: "demo", clientSecret: "",
        authorizationURL: URL(string: "https://example.invalid/authorize")!,
        tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://demo",
        scopes: []),
      secretKey: "demo", secrets: secrets, transport: transport), transport: transport)
  try await provider.connect()
  let path = try RemotePath("/folder/" + sample[0])
  #expect(try await provider.stat(path).path == path)
  #expect(try await provider.list(path).isEmpty)
  var result = Data()
  for try await data in try await provider.read(path, range: nil) { result.append(data) }
  #expect(result == Data("demo".utf8))
  let requests = await transport.requests
  #expect(requests.allSatisfy { $0.url?.query == nil && $0.url?.fragment == nil })
}
