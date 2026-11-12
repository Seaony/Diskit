import Core
import Foundation
import Testing

@testable import CloudDrive

private actor DropboxRecoveryTransport: HTTPTransport {
  var replies: [Result<HTTPResponse, Error>]
  var requests: [URLRequest] = []
  init(_ replies: [Result<HTTPResponse, Error>]) { self.replies = replies }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !replies.isEmpty else { throw RemoteError.protocolError }
    return try replies.removeFirst().get()
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse { try await send(request) }
}

private func reply(_ json: String = "{}", status: Int = 200) -> Result<HTTPResponse, Error> {
  .success(HTTPResponse(status: status, body: Data(json.utf8)))
}
private func lookup(_ tag: String, offset: Int? = nil, finish: Bool = false) -> Result<
  HTTPResponse, Error
> {
  var value: [String: Any] = [".tag": tag]
  if let offset { value["correct_offset"] = offset }
  if finish { value = [".tag": "lookup_failed", "lookup_failed": value] }
  return .success(
    HTTPResponse(status: 409, body: try! JSONSerialization.data(withJSONObject: ["error": value])))
}
private func uploadFixture(_ transport: DropboxRecoveryTransport) throws -> (DropboxProvider, URL) {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture)),
    for: "dropbox")
  let configuration = OAuthConfiguration(
    clientID: "fixture", clientSecret: "",
    authorizationURL: URL(string: "https://example.invalid/auth")!,
    tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "diskit://fixture",
    scopes: [])
  let provider = DropboxProvider(
    session: OAuthSession(
      configuration: configuration, secretKey: "dropbox", secrets: secrets, transport: transport),
    uploadSessionThreshold: 1, chunkSize: 2)
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data("abcdef".utf8).write(to: file)
  return (provider, file)
}
private func argument(_ request: URLRequest) throws -> [String: Any] {
  let header = try #require(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
  return try #require(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
}

@Test(arguments: [false, true])
func dropboxExpiredUploadSessionRestartsWithoutOverwriting(finish: Bool) async throws {
  var replies = [reply(), reply(#"{"session_id":"expired"}"#)]
  if finish { replies += [reply(), reply()] }
  replies += [
    lookup("not_found", finish: finish), reply(#"{"session_id":"fresh"}"#), reply(), reply(),
    reply(),
  ]
  let transport = DropboxRecoveryTransport(replies)
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  try await provider.write(RemotePath("/sample"), from: file)
  let requests = await transport.requests
  let starts = requests.filter { $0.url?.lastPathComponent == "start" }
  #expect(starts.map(\.httpBody) == [Data("ab".utf8), Data("ab".utf8)])
  let final = try argument(try #require(requests.last))
  let commit = try #require(final["commit"] as? [String: Any])
  #expect(commit["mode"] as? String == "add")
  #expect(commit["strict_conflict"] as? Bool == true)
  #expect(commit["autorename"] as? Bool == false)
}

@Test(arguments: [false, true])
func dropboxUploadResumesAtServerConfirmedOffset(finish: Bool) async throws {
  var replies = [reply(), reply(#"{"session_id":"session"}"#)]
  if finish { replies += [reply(), reply()] }
  replies += [lookup("incorrect_offset", offset: finish ? 4 : 3, finish: finish)]
  replies += finish ? [reply(), reply()] : [reply(), reply(), reply()]
  let transport = DropboxRecoveryTransport(replies)
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  try await provider.write(RemotePath("/sample"), from: file)
  let requests = await transport.requests
  let resumed = requests[finish ? 5 : 3]
  let cursor = try #require(try argument(resumed)["cursor"] as? [String: Any])
  #expect(cursor["offset"] as? Int == (finish ? 4 : 3))
  #expect(resumed.httpBody == Data((finish ? "ef" : "de").utf8))
}

@Test func dropboxLostAppendResponseRetriesSameCursorThenResumes() async throws {
  let transport = DropboxRecoveryTransport([
    reply(), reply(#"{"session_id":"session"}"#), .failure(URLError(.networkConnectionLost)),
    lookup("incorrect_offset", offset: 4), reply(), reply(),
  ])
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  try await provider.write(RemotePath("/sample"), from: file)
  let requests = await transport.requests
  #expect(requests[2].httpBody == requests[3].httpBody)
  let original = try argument(requests[2]) as NSDictionary
  let retried = try argument(requests[3]) as NSDictionary
  #expect(original == retried)
  #expect(requests[4].httpBody == Data("ef".utf8))
}

@Test(arguments: [-1, 7])
func dropboxUploadRejectsImpossibleServerOffset(offset: Int) async throws {
  let transport = DropboxRecoveryTransport([
    reply(), reply(#"{"session_id":"session"}"#), lookup("incorrect_offset", offset: offset),
  ])
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.write(RemotePath("/sample"), from: file)
  }
  #expect(await transport.requests.count == 3)
}

@Test func dropboxRepeatedExpiredSessionStopsAfterOneRestart() async throws {
  let transport = DropboxRecoveryTransport([
    reply(), reply(#"{"session_id":"old"}"#), lookup("not_found"), reply(#"{"session_id":"new"}"#),
    lookup("not_found"),
  ])
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.write(RemotePath("/sample"), from: file)
  }
  #expect(await transport.requests.count == 5)
}

@Test func dropboxRepeatedIncorrectOffsetHasBoundedRecovery() async throws {
  let transport = DropboxRecoveryTransport(
    [reply(), reply(#"{"session_id":"session"}"#)]
      + Array(repeating: lookup("incorrect_offset", offset: 2), count: 4))
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  await #expect(throws: RemoteError.protocolError) {
    try await provider.write(RemotePath("/sample"), from: file)
  }
  #expect(await transport.requests.count == 6)
}

@Test func dropboxClosedUploadSessionNeverCreatesAnotherFile() async throws {
  let transport = DropboxRecoveryTransport([
    reply(), reply(#"{"session_id":"session"}"#), reply(), reply(), lookup("closed", finish: true),
  ])
  let (provider, file) = try uploadFixture(transport)
  defer { try? FileManager.default.removeItem(at: file) }
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EIO)) {
    try await provider.write(RemotePath("/sample"), from: file)
  }
  #expect(await transport.requests.filter { $0.url?.lastPathComponent == "start" }.count == 1)
}
