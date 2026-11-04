import Core
import Foundation
import Testing

@testable import CloudDrive

private actor GoogleRecoveryHTTP: HTTPTransport {
  enum Scenario: Sendable { case expired, interrupted, serverError, completed, endlessExpiry, conflict, invalidRange, stalled, cancelled, prematureSuccess }
  let scenario: Scenario
  var starts = 0
  var chunks: [URLRequest] = []
  var queries = 0
  var names = 0
  init(_ scenario: Scenario) { self.scenario = scenario }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let url = try #require(request.url)
    if url.host == "www.googleapis.com", url.path == "/drive/v3/about" {
      return HTTPResponse(status: 200)
    }
    if url.host == "www.googleapis.com", url.path == "/drive/v3/files" {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      #expect(query.first { $0.name == "q" }?.value == "'root' in parents and name = 'file' and trashed = false")
      names += 1
      return HTTPResponse(status: 200, body: Data(
        (scenario == .conflict && names > 1 ? #"{"files":[{"id":"existing"}]}"# : #"{"files":[]}"#).utf8))
    }
    if url.host == "www.googleapis.com", url.path == "/upload/drive/v3/files" {
      #expect(request.httpMethod == "POST")
      starts += 1
      return HTTPResponse(status: 200, headers: ["Location": "https://uploads.example.invalid/session\(starts)"])
    }
    guard url.host == "uploads.example.invalid", url.path == "/session\(starts)" else {
      Issue.record("未登记请求：\(url)")
      throw RemoteError.protocolError
    }
    if request.httpMethod == "DELETE" { return HTTPResponse(status: 204) }
    if request.value(forHTTPHeaderField: "Content-Range") == "bytes */6291456" {
      queries += 1
      #expect(request.httpBody?.isEmpty == true)
      #expect(request.value(forHTTPHeaderField: "Content-Length") == "0")
      if scenario == .completed { return HTTPResponse(status: 201) }
      return HTTPResponse(status: 308, headers: ["Range": scenario == .invalidRange ? "bytes=0-99999999" : "bytes=0-1048575"])
    }
    chunks.append(request)
    if scenario == .endlessExpiry || (starts == 1 && [.expired, .conflict].contains(scenario)) {
      return HTTPResponse(status: 404)
    }
    if scenario == .cancelled { throw CancellationError() }
    if scenario == .stalled { return HTTPResponse(status: 308) }
    if scenario == .serverError, queries == 0 { return HTTPResponse(status: 503) }
    if [.interrupted, .completed, .invalidRange].contains(scenario), queries == 0 {
      throw URLError(.networkConnectionLost)
    }
    return HTTPResponse(status: 201)
  }
}

private func recoveryGoogle(_ http: GoogleRecoveryHTTP) throws -> GoogleDriveProvider {
  let secrets = MemorySecretStore()
  try secrets.write(JSONEncoder().encode(OAuthToken(
    accessToken: "local", refreshToken: "local", expiresAt: .distantFuture)), for: "recovery")
  return GoogleDriveProvider(session: OAuthSession(configuration: OAuthConfiguration(
    clientID: "local", clientSecret: "", authorizationURL: URL(string: "https://local.invalid/auth")!,
    tokenURL: URL(string: "https://local.invalid/token")!, redirectURI: "kayoi://test", scopes: []),
    secretKey: "recovery", secrets: secrets, transport: http))
}

@Test(arguments: [GoogleRecoveryHTTP.Scenario.expired, .interrupted, .serverError, .completed])
private func googleUploadRecoversSessionAndServerOffset(_ scenario: GoogleRecoveryHTTP.Scenario) async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data(repeating: 7, count: 6291456).write(to: file)
  let http = GoogleRecoveryHTTP(scenario)
  let provider = try recoveryGoogle(http)
  try await provider.connect()
  try await provider.write(RemotePath("/file"), from: file)
  let chunks = await http.chunks
  if scenario == .expired {
    #expect(await http.starts == 2)
    #expect(chunks.last?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-6291455/6291456")
  } else {
    #expect(await http.starts == 1)
    #expect(await http.queries == 1)
    if scenario == .completed { #expect(chunks.count == 1) }
    if scenario == .interrupted || scenario == .serverError {
      #expect(chunks.last?.value(forHTTPHeaderField: "Content-Range") == "bytes 1048576-6291455/6291456")
      #expect(chunks.last?.httpBody?.count == 5242880)
    }
  }
}

@Test(arguments: [GoogleRecoveryHTTP.Scenario.endlessExpiry, .conflict, .invalidRange, .stalled, .cancelled, .prematureSuccess])
private func googleUploadRecoveryIsBoundedAndDoesNotOverwrite(_ scenario: GoogleRecoveryHTTP.Scenario) async throws {
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data(repeating: 7, count: scenario == .prematureSuccess ? 9 * 1024 * 1024 : 6291456).write(to: file)
  let http = GoogleRecoveryHTTP(scenario)
  let provider = try recoveryGoogle(http)
  try await provider.connect()
  do {
    try await provider.write(RemotePath("/file"), from: file)
    Issue.record("恢复必须拒绝冲突、无效偏移和无进展")
  } catch {
    switch scenario {
    case .conflict: #expect(error as? RemoteError == .posix(EEXIST))
    case .invalidRange, .prematureSuccess: #expect(error as? RemoteError == .protocolError)
    case .cancelled: #expect(error is CancellationError)
    default: #expect(error as? RemoteError == .posix(ETIMEDOUT))
    }
  }
  #expect(await http.starts <= 4)
  if scenario == .conflict {
    #expect(await http.starts == 1)
  }
  if scenario == .stalled { #expect(await http.chunks.count == 4) }
  if scenario == .cancelled {
    #expect(await http.chunks.count == 1)
    #expect(await http.queries == 0)
    #expect(await http.starts == 1)
  }
}
