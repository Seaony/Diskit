import Foundation

public enum GoogleDesktopOAuth {
  public static func redirectURI(clientID: String) -> String {
    let suffix = ".apps.googleusercontent.com"
    guard clientID.hasSuffix(suffix) else { return "" }
    let identifier = clientID.dropLast(suffix.count)
    guard !identifier.isEmpty,
      identifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      })
    else { return "" }
    return "com.googleusercontent.apps.\(identifier):/oauth2redirect/google"
  }
}
