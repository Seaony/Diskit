import Foundation

struct PerformanceTimeline: Encodable, Sendable {
  struct Event: Encodable, Sendable {
    let name: String
    let tick: UInt64
    let elapsedMilliseconds: Double?
  }
  let processID: Int32
  let processStartTick: UInt64
  let nanosecondsPerTick: Double
  let measurementBoundary =
    "visible NSView draw completed; not compositor presentation or physical menu click"
  private(set) var events: [Event] = []
  private var menuRecorded = false
  private var pendingPanelRequest: UInt64?

  var needsMenuDraw: Bool { !menuRecorded }
  var needsPanelDraw: Bool { pendingPanelRequest != nil }

  enum CodingKeys: CodingKey {
    case processID, processStartTick, nanosecondsPerTick, measurementBoundary, events
  }

  mutating func requestPanel(at tick: UInt64) {
    pendingPanelRequest = tick
    events.append(Event(name: "panel_open_request", tick: tick, elapsedMilliseconds: nil))
  }

  mutating func drewMenu(at tick: UInt64) -> Bool {
    guard !menuRecorded, tick >= processStartTick else { return false }
    menuRecorded = true
    events.append(
      Event(
        name: "menu_software_draw_ready", tick: tick,
        elapsedMilliseconds: milliseconds(from: processStartTick, to: tick)))
    return true
  }

  mutating func drewPanel(at tick: UInt64) -> Bool {
    guard let request = pendingPanelRequest, tick >= request else { return false }
    pendingPanelRequest = nil
    events.append(
      Event(
        name: "panel_software_draw_ready", tick: tick,
        elapsedMilliseconds: milliseconds(from: request, to: tick)))
    return true
  }

  private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) * nanosecondsPerTick / 1_000_000
  }
}
