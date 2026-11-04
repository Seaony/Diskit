import Core

enum ConnectionTypeFocus {
  static func isFocused(_ kind: ConnectionKind, selection: ConnectionKind?, gridFocused: Bool)
    -> Bool
  {
    gridFocused && selection == kind
  }
}
