import Foundation
import Testing

@testable import CloudDrive

@Test func googleDesktopRedirectUsesReversedClientIdentifierAndSingleSlash() throws {
  let redirect = GoogleDesktopOAuth.redirectURI(clientID: "123-example.apps.googleusercontent.com")
  #expect(redirect == "com.googleusercontent.apps.123-example:/oauth2redirect/google")
  let url = try #require(URLComponents(string: redirect))
  #expect(url.scheme == "com.googleusercontent.apps.123-example")
  #expect(url.host == nil)
  #expect(url.path == "/oauth2redirect/google")
}

@Test(arguments: [
  "", ".apps.googleusercontent.com", "example", "123.apps.googleusercontent.com.evil",
  "x/y.apps.googleusercontent.com", "x y.apps.googleusercontent.com",
  "x:code.apps.googleusercontent.com",
])
func googleDesktopRedirectRejectsInvalidClientIdentifier(_ client: String) {
  #expect(GoogleDesktopOAuth.redirectURI(clientID: client).isEmpty)
}
