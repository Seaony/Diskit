import AppKit
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

actor EditorLoginProvider: RemoteFileProvider {
  nonisolated let capabilities = ProviderCapabilities(
    canWrite: false, canRename: false, canMove: false, canDelete: false, supportsRangeRead: true)
  private(set) var connects = 0
  private(set) var disconnects = 0
  let capacityFailure: Bool
  init(capacityFailure: Bool = false) { self.capacityFailure = capacityFailure }
  func connect() async throws { connects += 1 }
  func disconnect() async { disconnects += 1 }
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
  let dependencies = AppModelDependencies(
    location: location, secrets: MemorySecretStore(), preferences: preferences,
    smb: DemoMountService(delay: {}), httpTransport: transport,
    updates: UpdateController(isDemo: true),
    system: AppSystemServices(
      open: { _ in }, copy: { _ in },
      alert: { _, _, _, completion in completion(.alertFirstButtonReturn) },
      requestNotifications: {}, notificationStatus: { .denied }, notify: { _ in }),
    info: infoOverride ?? [:], providerFactory: { _ in provider })
  let app = AppModel(options: options, dependencies: dependencies)
  app.configureConnections()
  return app
}
