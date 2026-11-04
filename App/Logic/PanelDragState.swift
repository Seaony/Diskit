import Foundation

struct PanelDragState {
  private(set) var sourceID: UUID?
  private(set) var isDragging = false
  var publishedSourceID: UUID? { isDragging ? sourceID : nil }

  mutating func prepare(_ id: UUID) {
    sourceID = id
    isDragging = false
  }
  mutating func didBegin() { isDragging = sourceID != nil }
  mutating func finish() {
    sourceID = nil
    isDragging = false
  }
}
