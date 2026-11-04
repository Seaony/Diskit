import Core
import CoreTestSupport
import Foundation
import Testing

@testable import CloudDrive

private actor OneDriveRecoveryHTTP: HTTPTransport {
  let mode: String
  var creations = 0
  var queries = 0
  var ranges: [String] = []
  var bodies: [Data] = []
  var deleted = 0
  init(_ mode: String) { self.mode = mode }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let url = request.url!
    if url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root" {
      return HTTPResponse(status: 200)
    }
    if url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root:/recovery.bin" {
      if mode == "conflict", creations == 1 {
        return HTTPResponse(status: 200, body: Data(#"{"id":"other","name":"recovery.bin"}"#.utf8))
      }
      return HTTPResponse(status: 404)
    }
    if url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root:/recovery.bin:/createUploadSession" {
      #expect(request.httpMethod == "POST")
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      #expect((body["item"] as? [String: String])?["@microsoft.graph.conflictBehavior"] == "fail")
      creations += 1
      return HTTPResponse(status: 200, body: Data("{\"uploadUrl\":\"https://upload.example.invalid/session\(creations)\"}".utf8))
    }
    guard url.host == "upload.example.invalid", url.path == "/session\(creations)" else {
      throw RemoteError.protocolError
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    if request.httpMethod == "DELETE" { deleted += 1; return HTTPResponse(status: 204) }
    if request.httpMethod == "GET" {
      queries += 1
      return HTTPResponse(status: 200, body: Data(#"{"nextExpectedRanges":["327680-"]}"#.utf8))
    }
    throw RemoteError.protocolError
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    #expect(request.url?.absoluteString == "https://upload.example.invalid/session\(creations)")
    #expect(request.httpMethod == "PUT")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    ranges.append(request.value(forHTTPHeaderField: "Content-Range") ?? "")
    bodies.append(request.httpBody ?? Data())
    if mode == "stalled" {
      return HTTPResponse(status: 202, body: Data(#"{"nextExpectedRanges":["0-"]}"#.utf8))
    }
    if mode == "alwaysExpired" || ((mode == "expired" || mode == "conflict") && creations == 1) {
      return HTTPResponse(status: 404)
    }
    if ranges.count == 1 {
      switch mode {
      case "network": throw URLError(.networkConnectionLost)
      case "range": return HTTPResponse(status: 416)
      case "server": return HTTPResponse(status: 503)
      case "invalid": return HTTPResponse(status: 202, body: Data(#"{"nextExpectedRanges":["999999-"]}"#.utf8))
      default: return HTTPResponse(status: 202, body: Data(#"{"nextExpectedRanges":["327680-"]}"#.utf8))
      }
    }
    if request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-327679/327683" {
      return HTTPResponse(status: 202, body: Data(#"{"nextExpectedRanges":["327680-"]}"#.utf8))
    }
    return HTTPResponse(status: 201)
  }
}

private func recoveryProvider(_ http: OneDriveRecoveryHTTP) throws -> OneDriveProvider {
  let secrets = TestSecretStore()
  try secrets.write(JSONEncoder().encode(OAuthToken(
    accessToken: "local", refreshToken: "local", expiresAt: .distantFuture)), for: "recovery")
  let session = OAuthSession(configuration: OAuthConfiguration(
    clientID: "local", clientSecret: "local", authorizationURL: URL(string: "https://oauth.example.invalid/auth")!,
    tokenURL: URL(string: "https://oauth.example.invalid/token")!, redirectURI: "kayoi://test", scopes: []),
    secretKey: "recovery", secrets: secrets, transport: http)
  return OneDriveProvider(session: session, transport: http, uploadSessionThreshold: 0,
    chunkSize: 327680, recoverySleep: { _ in })
}

@Test(arguments: ["expired", "network", "range", "server"])
func oneDriveRecoversUploadSessionFromServerOffset(mode: String) async throws {
  let http = OneDriveRecoveryHTTP(mode)
  let provider = try recoveryProvider(http)
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  var data = Data(repeating: 1, count: 327680)
  data.append(Data([7, 8, 9]))
  try data.write(to: file)
  try await provider.connect()
  try await provider.write(RemotePath("/recovery.bin"), from: file)
  #expect(await http.creations == (mode == "expired" ? 2 : 1))
  #expect(await http.queries == (mode == "expired" ? 0 : 1))
  #expect(await http.ranges.last == "bytes 327680-327682/327683")
  #expect(await http.bodies.last == Data([7, 8, 9]))
  #expect(await http.deleted == 0)
}

@Test(arguments: ["alwaysExpired", "conflict", "invalid", "stalled"])
func oneDriveRecoveryIsBoundedAndNeverOverwrites(mode: String) async throws {
  let http = OneDriveRecoveryHTTP(mode)
  let provider = try recoveryProvider(http)
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data(repeating: 1, count: 327683).write(to: file)
  try await provider.connect()
  let expected: RemoteError = mode == "conflict" ? .posix(EEXIST)
    : mode == "invalid" ? .protocolError : mode == "stalled" ? .posix(EIO) : .posix(ENOENT)
  await #expect(throws: expected) {
    try await provider.write(RemotePath("/recovery.bin"), from: file)
  }
  #expect(await http.creations == (mode == "alwaysExpired" ? 3 : 1))
  #expect(await http.deleted == 1)
  if mode == "stalled" { #expect(await http.ranges.count == 4) }
}
