import Core
import Foundation
import Testing

@testable import CloudDrive

private actor DropboxRequestTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  let missing: Bool
  init(missing: Bool = true) { self.missing = missing }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard request.httpMethod == "POST" else { return HTTPResponse(status: 405) }
    switch request.url?.absoluteString {
    case "https://api.dropboxapi.com/2/users/get_current_account":
      return response(#"{"account_id":"demo","name":{"display_name":"测试账号"}}"#)
    case "https://api.dropboxapi.com/2/files/list_folder":
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      guard body["path"] as? String == "" else { return HTTPResponse(status: 400) }
      return response(#"{"entries":[],"cursor":"done","has_more":false}"#)
    case "https://api.dropboxapi.com/2/files/get_metadata":
      return missing
        ? response(
          #"{"error_summary":"path/not_found/","error":{".tag":"path","path":{".tag":"not_found"}}}"#,
          status: 409)
        : response(#"{"error":{".tag":"path","path":{".tag":"restricted_content"}}}"#, status: 409)
    case "https://api.dropboxapi.com/2/files/move_v2":
      return response(#"{"metadata":{"name":"目标😀.txt"}}"#)
    case "https://content.dropboxapi.com/2/files/upload":
      try validateHeader(request)
      return response("{}")
    default: return HTTPResponse(status: 404)
    }
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    requests.append(request)
    guard request.url?.absoluteString == "https://content.dropboxapi.com/2/files/download" else {
      throw RemoteError.posix(ENOENT)
    }
    try validateHeader(request)
    return HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream {
        $0.yield(Data("demo".utf8))
        $0.finish()
      })
  }
  private func validateHeader(_ request: URLRequest) throws {
    guard let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
      header.utf8.allSatisfy({ $0 < 127 })
    else { throw RemoteError.protocolError }
    _ = try JSONSerialization.jsonObject(with: Data(header.utf8))
  }
  private func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(json.utf8))
  }
}

private func dropboxProvider(_ transport: DropboxRequestTransport) throws -> DropboxProvider {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "demo", refreshToken: nil,
        expiresAt: .distantFuture)), for: "demo")
  return DropboxProvider(
    session: OAuthSession(
      configuration: OAuthConfiguration(
        clientID: "demo", clientSecret: "",
        authorizationURL: URL(string: "https://example.invalid/authorize")!,
        tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://demo",
        scopes: []),
      secretKey: "demo", secrets: secrets, transport: transport))
}

@Test func dropboxProfileDecodesDocumentedDisplayName() async throws {
  let provider = try dropboxProvider(DropboxRequestTransport())
  try await provider.connect()
  #expect(try await provider.profile().nickname == "测试账号")
}

@Test func dropboxRootUsesEmptyPath() async throws {
  let provider = try dropboxProvider(DropboxRequestTransport())
  try await provider.connect()
  #expect(try await provider.list(RemotePath("/")).isEmpty)
}

@Test func dropboxMissingDestinationAllowsMove() async throws {
  let transport = DropboxRequestTransport()
  let provider = try dropboxProvider(transport)
  try await provider.connect()
  try await provider.move(RemotePath("/源文件.txt"), to: RemotePath("/目标😀.txt"))
  let requests = await transport.requests
  #expect(requests.last?.url?.path == "/2/files/move_v2")
  let body = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
  #expect(body["from_path"] as? String == "/源文件.txt")
  #expect(body["to_path"] as? String == "/目标😀.txt")
  #expect(body["autorename"] as? Bool == false)
}

@Test func dropboxUnknownLookupFailureNeverMoves() async throws {
  let transport = DropboxRequestTransport(missing: false)
  let provider = try dropboxProvider(transport)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.move(RemotePath("/source"), to: RemotePath("/destination"))
  }
  #expect(await transport.requests.count == 2)
}

@Test func dropboxContentHeadersRoundTripUnicodeAndDEL() async throws {
  let transport = DropboxRequestTransport()
  let provider = try dropboxProvider(transport)
  try await provider.connect()
  let path = try RemotePath(#"/中文😀 + # "quoted" \ "# + "\u{7f}.txt")
  for try await _ in try await provider.read(path, range: nil) {}
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("demo".utf8).write(to: file)
  try await provider.write(path, from: file)
  let headers = await transport.requests.compactMap {
    $0.value(forHTTPHeaderField: "Dropbox-API-Arg")
  }
  #expect(headers.count == 2)
  for header in headers {
    #expect(header.utf8.allSatisfy { $0 < 127 })
    #expect(header.contains("\\u007f"))
    let object = try JSONSerialization.jsonObject(with: Data(header.utf8)) as! [String: Any]
    #expect(object["path"] as? String == path.value)
  }
}
