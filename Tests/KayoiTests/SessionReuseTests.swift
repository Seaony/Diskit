import CloudDrive
import Core
import Foundation
import S3Drive
import Testing

@MainActor @Test(arguments: [ConnectionKind.aliyunDrive, .pikPak, .tianyiDrive])
func appReusesAccountSessionsAcrossRequests(kind: ConnectionKind) {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  func session(_ connection: Connection) -> AnyObject {
    switch kind {
    case .aliyunDrive: model.aliyunSession(for: connection)
    case .pikPak: model.pikPakSession(for: connection)
    default: model.tianyiSession(for: connection)
    }
  }
  var connection = Connection(kind: kind, name: "first")
  let first = session(connection)
  #expect(first === session(connection))
  connection.name = "renamed"
  connection.params["nickname"] = "display only"
  #expect(first === session(connection))
  #expect(first !== session(Connection(kind: kind)))
}

@MainActor @Test func appKeepsServiceAndTianyiScopeSessionsSeparate() {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  var connection = Connection(kind: .quark)
  let quark = model.quarkSession(for: connection)
  #expect(quark === model.quarkSession(for: connection))
  connection.kind = .ucDrive
  #expect(quark !== model.quarkSession(for: connection))
  connection.kind = .tianyiDrive
  connection.params = ["scope": "family", "familyID": "first"]
  let personal = model.tianyiSession(for: connection, personal: true)
  let family = model.tianyiSession(for: connection)
  #expect(personal !== family)
  #expect(personal === model.tianyiSession(for: connection, personal: true))
  #expect(family === model.tianyiSession(for: connection))
  connection.params["familyID"] = "second"
  #expect(family !== model.tianyiSession(for: connection))
  #expect(personal === model.tianyiSession(for: connection, personal: true))
}

@MainActor @Test func appRemovedConnectionReleasesCachedSession() async throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let connection = try #require(model.connections.connections.first { $0.kind == .aliyunDrive })
  let original = model.aliyunSession(for: connection)
  try await model.connections.remove(connection)
  #expect(!model.connections.connections.contains { $0.id == connection.id })
  #expect(original !== model.aliyunSession(for: connection))
}

@MainActor @Test func cachedOAuthSessionSeesUpdatedInMemoryCredentials() async throws {
  let cache = RemoteSessionCache()
  let secrets = MemorySecretStore()
  let connection = Connection(kind: .googleDrive)
  func configuration(_ client: String) -> OAuthConfiguration {
    OAuthConfiguration(
      clientID: client, clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/auth")!,
      tokenURL: URL(string: "https://example.invalid/token")!, redirectURI: "kayoi://test",
      scopes: [])
  }
  func session(_ client: String) -> OAuthSession {
    let config = configuration(client)
    return cache.value(for: connection, configuration: config) {
      OAuthSession(configuration: config, secretKey: "account", secrets: secrets)
    }
  }
  let original = session("first")
  #expect(try await !original.hasToken())
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "new", refreshToken: "rotated", expiresAt: .distantFuture)),
    for: "account")
  #expect(session("first") === original)
  #expect(try await original.tokenForTesting()?.accessToken == "new")
  try secrets.delete("account")
  #expect(try await !original.hasToken())
  #expect(session("second") !== original)
}

@MainActor @Test func appDiscardsOnlyUnsavedSessionCache() throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  let draft = Connection(kind: .aliyunDrive)
  let draftSession = model.aliyunSession(for: draft)
  model.discardUnsavedSessions(for: draft)
  #expect(draftSession !== model.aliyunSession(for: draft))
  let saved = try #require(model.connections.connections.first { $0.kind == .aliyunDrive })
  let savedSession = model.aliyunSession(for: saved)
  model.discardUnsavedSessions(for: saved)
  #expect(savedSession === model.aliyunSession(for: saved))
}

@MainActor @Test(arguments: [ConnectionKind.lanzou, .mobileCloud, .thunderDrive, .s3])
func appReusesConfiguredSessionsAndReplacesChangedCredentials(kind: ConnectionKind) throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  var connection = Connection(kind: kind, name: "first", params: ["phone": "local-only"])
  try model.secrets.write(Data("phpdisk_info=local".utf8), for: connection.passwordKey)
  func session(_ value: Connection) throws -> AnyObject {
    switch value.kind {
    case .lanzou: return try model.lanzouSession(for: value)
    case .mobileCloud: return try model.mobileCloudSession(for: value)
    case .thunderDrive: return try model.xunleiSession(for: value)
    default:
      return model.s3Transport(
        for: value,
        configuration: S3Configuration(
          endpoint: URL(string: "https://example.invalid")!, region: "local", bucket: "local",
          accessKey: "local", secretKey: try model.savedRemoteSecret(for: value)))
    }
  }
  let original = try session(connection)
  #expect(try original === session(connection))
  connection.name = "renamed"
  #expect(try original === session(connection))
  try model.secrets.write(Data("phpdisk_info=updated".utf8), for: connection.passwordKey)
  let replacement = try session(connection)
  #expect(original !== replacement)
  #expect(try replacement === session(connection))
  model.discardUnsavedSessions(for: connection)
  #expect(try replacement !== session(connection))
}

@MainActor @Test func appLanzouConfigurationChangeReplacesSharedSession() throws {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  var connection = Connection(
    kind: .lanzou, params: ["authMode": "share", "shareURL": "https://example.invalid/first"])
  let original = try model.lanzouSession(for: connection)
  connection.params["shareURL"] = "https://example.invalid/second"
  let replacement = try model.lanzouSession(for: connection)
  #expect(original !== replacement)
  #expect(
    replacement.configuration.authentication
      == .share(url: URL(string: "https://example.invalid/second")!, password: nil))
}
