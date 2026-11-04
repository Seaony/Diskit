import Core
import Foundation
import Testing

@testable import CloudDrive

private let limitConfiguration = OAuthConfiguration(
  clientID: "local", clientSecret: "local",
  authorizationURL: URL(string: "https://example.invalid/auth")!,
  tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://test", scopes: [])

private actor ProfileConcurrencyProbe: HTTPTransport {
  let host: String
  let path: String
  let json: String
  var active = 0
  var maximum = 0
  var count = 0
  init(host: String, path: String, json: String) {
    self.host = host
    self.path = path
    self.json = json
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.host == host, request.url?.path == path else {
      return HTTPResponse(status: 404)
    }
    active += 1
    maximum = max(maximum, active)
    count += 1
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(30))
    return HTTPResponse(status: 200, body: Data(json.utf8))
  }
}

@Test(arguments: ["baidu", "115", "123", "oneDrive", "google", "dropbox"])
func cloudProvidersShareAccountRequestAllowance(kind: String) async throws {
  let responses: [String: (String, String, String)] = [
    "baidu": (
      "pan.baidu.com", "/rest/2.0/xpan/nas", #"{"errno":0,"uk":1,"netdisk_name":"Tester"}"#
    ),
    "115": (
      "proapi.115.com", "/open/user/info",
      #"{"state":true,"data":{"user_id":1,"user_name":"Tester","rt_space_info":{}}}"#
    ),
    "123": (
      "open-api.123pan.com", "/api/v1/user/info",
      #"{"code":0,"data":{"uid":1,"nickname":"Tester","headImage":"","spaceUsed":0,"spacePermanent":100,"spaceTemp":0}}"#
    ),
    "oneDrive": ("graph.microsoft.com", "/v1.0/me", #"{"id":"1","displayName":"Tester"}"#),
    "google": (
      "www.googleapis.com", "/drive/v3/about",
      #"{"user":{"permissionId":"1","displayName":"Tester"}}"#
    ),
    "dropbox": (
      "api.dropboxapi.com", "/2/users/get_current_account",
      #"{"account_id":"1","name":{"display_name":"Tester"}}"#
    ),
  ]
  let (host, path, json) = try #require(responses[kind])
  let probe = ProfileConcurrencyProbe(host: host, path: path, json: json)
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "local", refreshToken: "local", expiresAt: Date().addingTimeInterval(3600))),
    for: "account")
  func make() -> any OAuthProfileProviding {
    let session = OAuthSession(
      configuration: limitConfiguration, secretKey: "account", secrets: secrets, transport: probe)
    switch kind {
    case "baidu":
      return BaiduDriveProvider(
        configuration: BaiduDriveConfiguration(rootPath: "apps/test", appID: "test"),
        session: session, transport: probe)
    case "115": return Drive115Provider(session: session, transport: probe)
    case "123": return Drive123Provider(session: session, transport: probe)
    case "oneDrive": return OneDriveProvider(session: session, transport: probe)
    case "google": return GoogleDriveProvider(session: session)
    default: return DropboxProvider(session: session)
    }
  }
  let first = make()
  let second = make()
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<16 {
      group.addTask {
        let profile = try await (index.isMultiple(of: 2) ? first : second).profile()
        #expect(profile.nickname == "Tester")
      }
    }
    try await group.waitForAll()
  }
  let maximum = await probe.maximum
  #expect(maximum <= 4)
  #expect(maximum > 1)
  #expect(await probe.count == 16)
}

private actor RefreshStreamProbe: HTTPTransport {
  var refreshes = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.absoluteString == "https://example.invalid/token" else {
      return HTTPResponse(status: 404)
    }
    refreshes += 1
    return HTTPResponse(
      status: 200,
      body: Data(#"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    let accepted =
      request.url?.path == "/held"
      || request.value(forHTTPHeaderField: "Authorization") == "Bearer new"
    return HTTPStreamResponse(
      response: HTTPResponse(status: accepted ? 200 : 401),
      body: AsyncThrowingStream {
        $0.yield(Data([1]))
        $0.finish()
      })
  }
}

@Test func rejectedStreamReleasesAllowanceBeforeRefresh() async throws {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))),
    for: "account")
  let probe = RefreshStreamProbe()
  let session = OAuthSession(
    configuration: limitConfiguration, secretKey: "account", secrets: secrets, transport: probe)
  var held: [HTTPStreamResponse] = []
  for _ in 0..<3 {
    held.append(
      try await session.authorizedStream(
        URLRequest(url: URL(string: "https://example.invalid/held")!)))
  }
  let rejected = Task {
    try await session.authorizedStream(
      URLRequest(url: URL(string: "https://example.invalid/rejected")!))
  }
  for _ in 0..<200 {
    if await probe.refreshes == 1 { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  let refreshesBeforeReleasingOtherDownloads = await probe.refreshes
  #expect(refreshesBeforeReleasingOtherDownloads == 1)
  held.removeAll()
  let result = try await rejected.value
  #expect(result.response.status == 200)
  for try await _ in result.body {}
}

private actor OneDriveUploadConcurrencyProbe: HTTPTransport {
  var active = 0
  var maximum = 0
  var uploads = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.host == "graph.microsoft.com" {
      if request.url?.path == "/v1.0/me/drive/root" { return HTTPResponse(status: 200) }
      if request.httpMethod == "GET" { return HTTPResponse(status: 404) }
      if request.httpMethod == "POST", request.url?.path.hasSuffix("/createUploadSession") == true {
        return HTTPResponse(
          status: 200, body: Data(#"{"uploadUrl":"https://uploads.example.invalid/data"}"#.utf8))
      }
    }
    guard request.url?.absoluteString == "https://uploads.example.invalid/data",
      request.httpMethod == "PUT"
    else { return HTTPResponse(status: 404) }
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.httpBody == Data([1, 2]))
    active += 1
    maximum = max(maximum, active)
    uploads += 1
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(30))
    return HTTPResponse(status: 201)
  }
}

@Test func oneDriveDirectUploadsShareOAuthAccountAllowance() async throws {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(
        accessToken: "local", refreshToken: "local", expiresAt: Date().addingTimeInterval(3600))),
    for: "account")
  let probe = OneDriveUploadConcurrencyProbe()
  var providers: [OneDriveProvider] = []
  for _ in 0..<12 {
    let session = OAuthSession(
      configuration: limitConfiguration, secretKey: "account", secrets: secrets, transport: probe)
    let provider = OneDriveProvider(
      session: session, transport: probe, uploadSessionThreshold: 0, chunkSize: 2)
    try await provider.connect()
    providers.append(provider)
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try Data([1, 2]).write(to: file)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for (index, provider) in providers.enumerated() {
      group.addTask { try await provider.write(try RemotePath("/file\(index)"), from: file) }
    }
    try await group.waitForAll()
  }
  let maximum = await probe.maximum
  #expect(maximum <= 4)
  #expect(maximum > 1)
  #expect(await probe.uploads == 12)
}
