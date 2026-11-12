import AliyunDrive
import CloudDrive
import Foundation
import Testing

@Test func googleDesktopCallbackRequiresExactRedirectAndState() throws {
  let redirect = GoogleDesktopOAuth.redirectURI(clientID: "123-example.apps.googleusercontent.com")
  let callback = URL(string: redirect + "?code=local-code&state=expected")!
  #expect(
    try OAuthCallback.code(from: callback, redirectURI: redirect, state: "expected") == "local-code"
  )
  for incorrect in [
    redirect + "?code=local-code&state=wrong",
    redirect + "?code=first&code=second&state=expected",
    "com.googleusercontent.apps.other:/oauth2redirect/google?code=local-code&state=expected",
    "com.googleusercontent.apps.123-example://oauth2redirect/google?code=local-code&state=expected",
  ] {
    #expect(throws: OAuthCallbackError.self) {
      try OAuthCallback.code(
        from: URL(string: incorrect)!, redirectURI: redirect, state: "expected")
    }
  }
}
