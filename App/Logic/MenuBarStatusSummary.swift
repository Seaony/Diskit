import Core

struct MenuBarStatusSummary: Equatable {
  let attention: Int
  let busy: Bool
  let mounted: Int

  init(states: [ConnectionState]) {
    attention = states.filter { state in
      if case .failed = state { return true }
      return state == .needsLogin
    }.count
    busy = states.contains { $0 == .connecting || $0 == .awaitingAuthorization }
    mounted = states.filter { if case .mounted = $0 { return true }; return false }.count
  }

  func shouldPulse(reduceMotion: Bool) -> Bool { attention == 0 && busy && !reduceMotion }

  func symbol(pulse: Bool) -> String {
    if attention == 0 && busy { return pulse ? "externaldrive.fill" : "externaldrive" }
    return mounted > 0 ? "externaldrive.fill" : "externaldrive"
  }
}
