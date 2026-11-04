import Foundation

struct PanelSelection {
  struct ScrollRequest: Equatable {
    let id = UUID()
    let connectionID: UUID
  }
  private(set) var id: UUID?
  private(set) var scrollRequest: ScrollRequest?

  mutating func select(_ id: UUID?, reveal: Bool) {
    self.id = id
    scrollRequest = reveal ? id.map { ScrollRequest(connectionID: $0) } : nil
  }
}
