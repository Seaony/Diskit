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

  // 菜单栏标签只能显示单色模板图，有问题时用带感叹号的符号代替彩色圆点
  func symbol(pulse: Bool) -> String {
    if attention > 0 { return mounted > 0 ? "externaldrive.fill.badge.exclamationmark" : "externaldrive.badge.exclamationmark" }
    if busy { return pulse ? "externaldrive.fill" : "externaldrive" }
    return mounted > 0 ? "externaldrive.fill" : "externaldrive"
  }
}
