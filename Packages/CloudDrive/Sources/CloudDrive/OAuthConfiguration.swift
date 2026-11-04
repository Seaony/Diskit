import Foundation

public struct OAuthConfiguration: Sendable, Equatable {
  public let clientID: String
  public let clientSecret: String
  public let authorizationURL: URL
  public let tokenURL: URL
  public let refreshTokenURL: URL?
  public let redirectURI: String
  public let scopes: [String]
  public let additionalAuthorizationItems: [String: String]
  public let scopeSeparator: String
  public let tokenRequestMethod: String
  public let tokenRequestPlacement: OAuthTokenRequestPlacement
  public let tokenResponseDataKey: String?
  public let refreshGrantIncludesClientCredentials: Bool
  public let refreshGrantIncludesRedirectURI: Bool
  public let usesPKCE: Bool
  public init(
    clientID: String, clientSecret: String, authorizationURL: URL, tokenURL: URL,
    refreshTokenURL: URL? = nil, redirectURI: String, scopes: [String],
    additionalAuthorizationItems: [String: String] = [:], scopeSeparator: String = " ",
    tokenRequestMethod: String = "POST",
    tokenRequestPlacement: OAuthTokenRequestPlacement = .formBody,
    tokenResponseDataKey: String? = nil,
    refreshGrantIncludesClientCredentials: Bool = true,
    refreshGrantIncludesRedirectURI: Bool = false,
    usesPKCE: Bool = false
  ) {
    self.clientID = clientID
    self.clientSecret = usesPKCE ? "" : clientSecret
    self.authorizationURL = authorizationURL
    self.tokenURL = tokenURL
    self.refreshTokenURL = refreshTokenURL
    self.redirectURI = redirectURI
    self.scopes = scopes
    self.additionalAuthorizationItems = additionalAuthorizationItems
    self.scopeSeparator = scopeSeparator
    self.tokenRequestMethod = tokenRequestMethod
    self.tokenRequestPlacement = tokenRequestPlacement
    self.tokenResponseDataKey = tokenResponseDataKey
    self.refreshGrantIncludesClientCredentials = refreshGrantIncludesClientCredentials
    self.refreshGrantIncludesRedirectURI = refreshGrantIncludesRedirectURI
    self.usesPKCE = usesPKCE
  }
  public var isConfigured: Bool {
    !clientID.isEmpty && !redirectURI.isEmpty
  }
}
