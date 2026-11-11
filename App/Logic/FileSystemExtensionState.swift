import Foundation

enum FileSystemExtensionState: Equatable, Sendable {
  case checking, enabled, disabled, unavailable
}
