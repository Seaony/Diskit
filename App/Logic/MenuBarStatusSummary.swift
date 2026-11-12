import Core

enum MenuBarGlyphState: Equatable {
  case dimmedGlyph, glyph, filled
}

struct MenuBarStatusSummary: Equatable {
  let attention: Int
  let busy: Bool
  let mounted: Int

  init(states: [ConnectionState]) {
    attention =
      states.filter { state in
        if case .failed = state { return true }
        return state == .needsLogin
      }.count
    busy = states.contains { $0 == .connecting || $0 == .awaitingAuthorization }
    mounted =
      states.filter {
        if case .mounted = $0 { return true }
        return false
      }.count
  }

  func shouldPulse(reduceMotion: Bool) -> Bool { busy && !reduceMotion }

  // 提醒只加圆点，不改变字形或连接节奏。
  func glyph(pulse: Bool, reduceMotion: Bool) -> MenuBarGlyphState {
    if busy { return pulse && !reduceMotion ? .filled : .glyph }
    return mounted > 0 ? .glyph : .dimmedGlyph
  }
}
