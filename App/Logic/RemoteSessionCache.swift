import Core
import Foundation

@MainActor final class RemoteSessionCache {
  private struct Key: Hashable {
    let id: UUID
    let kind: ConnectionKind
    let type: ObjectIdentifier
    let slot: String
  }
  private struct Entry<Session: AnyObject, Configuration: Equatable> {
    let configuration: Configuration
    let session: Session
  }
  private var entries: [Key: Any] = [:]

  func value<Session: AnyObject, Configuration: Equatable>(
    for connection: Connection, configuration: Configuration, slot: String = "",
    create: () -> Session
  ) -> Session {
    let key = Key(
      id: connection.id, kind: connection.kind, type: ObjectIdentifier(Session.self), slot: slot)
    if let entry = entries[key] as? Entry<Session, Configuration>,
      entry.configuration == configuration
    {
      return entry.session
    }
    let session = create()
    entries[key] = Entry(configuration: configuration, session: session)
    return session
  }

  func remove(_ id: UUID) {
    entries = entries.filter { $0.key.id != id }
  }
}
