import Core

enum ProviderAccess {
  static func isReadOnly(_ capabilities: ProviderCapabilities?) -> Bool {
    guard let capabilities else { return false }
    return !capabilities.canWrite && !capabilities.canRename && !capabilities.canMove
      && !capabilities.canDelete
  }
}
