import Foundation
import Testing

@testable import AliyunDrive

@Test func OAuthCallbackRejectsOtherRoutesStatesAndRepeatedCodes() throws {
  let redirect = "kayoi://oauth/aliyun"
  #expect(
    try OAuthCallback.code(
      from: URL(string: redirect + "?state=nonce&code=accepted")!, redirectURI: redirect,
      state: "nonce") == "accepted")
  for url in [
    "other://oauth/aliyun?state=nonce&code=x", "kayoi://other/aliyun?state=nonce&code=x",
    "kayoi://oauth/wrong?state=nonce&code=x", redirect + "?state=wrong&code=x",
    redirect + "?state=nonce&code=x&code=y", redirect + "?state=nonce&state=nonce&code=x",
    redirect + "?state=nonce&error=access_denied",
  ] {
    #expect(throws: (any Error).self) {
      try OAuthCallback.code(from: URL(string: url)!, redirectURI: redirect, state: "nonce")
    }
  }
}
