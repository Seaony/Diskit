import Core
import Foundation

public struct AliyunConfiguration: Codable, Equatable, Sendable {
  public let clientID: String
  public let clientSecret: String
  public let redirectURI: String
  public init(clientID: String = "", clientSecret: String = "", redirectURI: String = "") {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.redirectURI = redirectURI
  }
  func validate() throws {
    guard !clientID.isEmpty, !clientSecret.isEmpty,
      let redirect = URL(string: redirectURI), redirect.scheme == "diskit"
    else {
      throw AliyunError.missingConfiguration
    }
  }
  public func authorizationURL(state: String) throws -> URL {
    try validate()
    guard !state.isEmpty else { throw AliyunError.invalidState }
    var parts = URLComponents(string: "https://openapi.alipan.com/oauth/authorize")!
    parts.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "user:base,file:all:read,file:all:write"),
      URLQueryItem(name: "style", value: "folder"),
      URLQueryItem(name: "state", value: state),
    ]
    guard let url = parts.url else { throw AliyunError.missingConfiguration }
    return url
  }
}
