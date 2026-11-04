import Core
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class ExpiryHTTP: HTTPTransport, Sendable {
  let requests = Mutex<[URLRequest]>([])
  let reply: @Sendable (URLRequest) throws -> HTTPResponse
  init(_ reply: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.reply = reply }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return try reply(request)
  }
}

private func expiryReply(_ text: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(text.utf8))
}

private func expirySession(_ transport: any HTTPTransport) throws -> OAuthSession {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture)),
    for: "expiry")
  return OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "local", clientSecret: "", authorizationURL: URL(string: "https://local.invalid/auth")!,
      tokenURL: URL(string: "https://local.invalid/token")!, redirectURI: "kayoi://local", scopes: []),
    secretKey: "expiry", secrets: secrets, transport: transport)
}

private func expiryQuery(_ request: URLRequest) -> [String: String] {
  Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Test(arguments: [false, true])
func baiduExpiredAccessTokenRetriesSamePartWithoutRestarting(businessCode: Bool) async throws {
  let first = Data(repeating: 1, count: 4 * 1024 * 1024)
  let last = Data([2])
  let http = ExpiryHTTP { request in
    let query = expiryQuery(request)
    if request.url?.path == "/token" { return expiryReply(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#) }
    switch query["method"] {
    case "uinfo": return expiryReply(#"{"errno":0,"uk":1,"vip_type":0}"#)
    case "list": return expiryReply(#"{"errno":0,"list":[]}"#)
    case "precreate": return expiryReply(#"{"errno":0,"uploadid":"original","block_list":[0,1],"return_type":1}"#)
    case "upload":
      if query["partseq"] == "1", query["access_token"] == "old" {
        return expiryReply(#"{"error_code":31045}"#, status: businessCode ? 200 : 401)
      }
      let hash = CloudDriveSupport.md5Hex(query["partseq"] == "0" ? first : last)
      return expiryReply("{\"md5\":\"\(hash)\"}")
    case "create": return expiryReply(#"{"errno":0,"fs_id":8}"#)
    default: throw RemoteError.protocolError
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try (first + last).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let provider = BaiduDriveProvider(configuration: BaiduDriveConfiguration(rootPath: "/apps/local", appID: "local"), session: try expirySession(http), transport: http)
  try await provider.connect()
  try await provider.write(RemotePath("/new"), from: file)
  let requests = http.requests.withLock { $0 }
  let parts = requests.filter { expiryQuery($0)["method"] == "upload" }
  #expect(parts.map { expiryQuery($0)["partseq"]! } == ["0", "1", "1"])
  #expect(parts.allSatisfy { expiryQuery($0)["uploadid"] == "original" })
  try #require(parts.count == 3)
  #expect(parts[1].httpBody == parts[2].httpBody)
  #expect(expiryQuery(parts[2])["access_token"] == "fresh")
  #expect(requests.filter { expiryQuery($0)["method"] == "precreate" }.count == 1)
  #expect(requests.filter { $0.url?.path == "/token" }.count == 1)
}
