import AppKit
import CloudDrive
import Core
import Foundation

actor EditorLoginHTTP: HTTPTransport {
  let response: @Sendable (URLRequest) throws -> HTTPResponse
  private(set) var requests: [URLRequest] = []
  init(response: @escaping @Sendable (URLRequest) throws -> HTTPResponse) {
    self.response = response
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try response(request)
  }
}

actor EditorLoginProvider: RemoteFileProvider, OAuthProfileProviding {
  nonisolated let capabilities = ProviderCapabilities(
    canWrite: false, canRename: false, canMove: false, canDelete: false, supportsRangeRead: true)
  private(set) var connects = 0
  private(set) var disconnects = 0
  let capacityFailure: Bool
  init(capacityFailure: Bool = false) { self.capacityFailure = capacityFailure }
  func connect() async throws { connects += 1 }
  func disconnect() async { disconnects += 1 }
  func profile() async throws -> OAuthProfile {
    OAuthProfile(
      userID: "fixture-user", nickname: "Fixture account",
      avatarURL: "https://fixture.invalid/avatar")
  }
  func spaceInfo() async throws -> SpaceInfo {
    if capacityFailure { throw RemoteError.unsupported }
    return SpaceInfo(total: 1000, used: 400)
  }
  func list(_ path: RemotePath) async throws -> [RemoteItem] { throw RemoteError.unsupported }
  func stat(_ path: RemotePath) async throws -> RemoteItem { throw RemoteError.unsupported }
  func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<
    Data, Error
  > { throw RemoteError.unsupported }
  func write(_ path: RemotePath, from localFile: URL) async throws { throw RemoteError.unsupported }
  func makeDirectory(_ path: RemotePath) async throws { throw RemoteError.unsupported }
  func remove(_ path: RemotePath, recursive: Bool) async throws { throw RemoteError.unsupported }
  func move(_ from: RemotePath, to: RemotePath) async throws { throw RemoteError.unsupported }
}

@MainActor final class EditorLoginOAuth: OAuthAuthorizing {
  var calls = 0
  func authorize(_ url: URL) async throws -> URL {
    calls += 1
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let redirect = query.first { $0.name == "redirect_uri" }?.value ?? "diskit://oauth/callback"
    var result = URLComponents(string: redirect)!
    result.queryItems = [
      URLQueryItem(name: "code", value: "local-code"),
      URLQueryItem(name: "state", value: query.first { $0.name == "state" }?.value),
    ]
    return result.url!
  }
  func cancel() {}
}

@MainActor final class EditorLoginWeb: WebLoginAuthorizing {
  let credentials: WebLoginCredentials
  init(_ credentials: WebLoginCredentials) { self.credentials = credentials }
  func authorize(
    service: WebLoginService, options: RuntimeOptions,
    validate: @escaping @MainActor (WebLoginCredentials) async throws -> Void
  ) async throws -> WebLoginCredentials {
    try await validate(credentials)
    return credentials
  }
  func cancel() {}
}

@MainActor func editorProductionApp(
  transport: any HTTPTransport, provider: EditorLoginProvider = EditorLoginProvider(),
  infoOverride: [String: Any]? = nil,
  options: RuntimeOptions = RuntimeOptions(environment: [:])
) -> AppModel {
  let location = LocalStorageLocation(
    home: FileManager.default.temporaryDirectory.appending(
      path: "DiskitEditorTests-" + UUID().uuidString))
  let preferences = UserDefaults(suiteName: "DiskitEditorTests." + UUID().uuidString)!
  var info: [String: Any] = [:]
  for service in ["ALIYUN", "BAIDU", "DRIVE115", "DRIVE123", "ONEDRIVE", "DROPBOX"] {
    info[service + "_CLIENT_ID"] = "local-client"
    info[service + "_CLIENT_SECRET"] = "local-secret"
    info[service + "_REDIRECT_URI"] = "diskit://oauth/callback"
  }
  info["GOOGLE_CLIENT_ID"] = "local-client.apps.googleusercontent.com"
  info["BAIDU_APP_ID"] = "local-app"
  let dependencies = AppModelDependencies(
    location: location, secrets: MemorySecretStore(), preferences: preferences,
    smb: DemoMountService(delay: {}), httpTransport: transport,
    updates: UpdateController(isDemo: true),
    system: AppSystemServices(
      open: { _ in }, copy: { _ in },
      alert: { _, _, _, completion in completion(.alertFirstButtonReturn) },
      requestNotifications: {}, notificationStatus: { .denied }, notify: { _ in }),
    info: infoOverride ?? info, providerFactory: { _ in provider })
  let app = AppModel(options: options, dependencies: dependencies)
  app.configureConnections()
  return app
}
