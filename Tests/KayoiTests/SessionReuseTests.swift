import CloudDrive
import Core
import Foundation
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
