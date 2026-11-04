import Core
import Foundation
import Testing

@testable import CloudDrive

@Test(arguments: [
  ["2026-01-02T03:04:05.123Z", "1767323045.123"],
  ["2026-01-02T03:04:05Z", "1767323045"],
  ["2026-01-02T03:04:05.123+08:00", "1767294245.123"],
  ["2026-01-02T03:04:05.123", "1767294245.123"],
  ["2026-01-02T03:04:05", "1767294245"],
  ["2026-01-02 03:04:05.123", "1767294245.123"],
])
func cloudTimestampsPreserveMillisecondsAndDefaultTimeZone(_ sample: [String]) {
  let value = CloudDriveSupport.parseDate(sample[0]).timeIntervalSince1970
  #expect(abs(value - Double(sample[1])!) < 0.00001)
}

private struct TimestampTransport: HTTPTransport {
  let responses: [String: HTTPResponse]
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    responses[request.url?.absoluteString ?? ""] ?? HTTPResponse(status: 404)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    throw RemoteError.protocolError
  }
}

@Test(
  arguments: ["google", "oneDrive", "dropbox"],
  ["2026-01-02T03:04:05.123Z", "2026-01-02T03:04:05.123"])
func officialProviderFileDatesPreserveMilliseconds(_ service: String, _ timestamp: String)
  async throws
{
  func json(_ object: [String: Any]) throws -> HTTPResponse {
    HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
  }
  var googleURL = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
  googleURL.queryItems = [
    URLQueryItem(name: "q", value: "'root' in parents and trashed = false"),
    URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
    URLQueryItem(name: "pageSize", value: "1000"),
  ]
  let http = TimestampTransport(responses: [
    "https://www.googleapis.com/drive/v3/about?fields=user": HTTPResponse(status: 200),
    googleURL.url!.absoluteString: try json([
      "files": [
        [
          "id": "demo", "name": "demo", "mimeType": "text/plain", "size": "4",
          "modifiedTime": timestamp,
        ]
      ]
    ]),
    "https://graph.microsoft.com/v1.0/me/drive/root": HTTPResponse(status: 200),
    "https://graph.microsoft.com/v1.0/me/drive/root/children": try json([
      "value": [["id": "demo", "name": "demo", "size": 4, "lastModifiedDateTime": timestamp]]
    ]),
    "https://api.dropboxapi.com/2/users/get_current_account": HTTPResponse(status: 200),
    "https://api.dropboxapi.com/2/files/list_folder": try json([
      "entries": [[".tag": "file", "name": "demo", "size": 4, "server_modified": timestamp]],
      "cursor": "done", "has_more": false,
    ]),
  ])
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "demo", refreshToken: nil, expiresAt: .distantFuture)), for: "demo")
  let session = OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "demo", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/authorize")!,
      tokenURL: URL(string: "https://example.invalid/token")!,
      redirectURI: "kayoi://demo", scopes: []), secretKey: "demo", secrets: secrets, transport: http
  )
  let provider: any RemoteFileProvider
  switch service {
  case "google": provider = GoogleDriveProvider(session: session)
  case "oneDrive": provider = OneDriveProvider(session: session, transport: http)
  default: provider = DropboxProvider(session: session)
  }
  try await provider.connect()
  let items = try await provider.list(RemotePath("/"))
  let item = try #require(items.first)
  #expect(abs(item.modified.timeIntervalSince1970 - 1_767_323_045.123) < 0.00001)
}
