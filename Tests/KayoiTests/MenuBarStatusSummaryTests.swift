import Core
import Foundation
import Testing

@Test func menuBarIdleAndReducedMotionNeverRequestPulse() {
  #expect(!MenuBarStatusSummary(states: []).shouldPulse(reduceMotion: false))
  #expect(!MenuBarStatusSummary(states: [.connecting]).shouldPulse(reduceMotion: true))
  #expect(MenuBarStatusSummary(states: [.connecting]).shouldPulse(reduceMotion: false))
  #expect(MenuBarStatusSummary(states: [.awaitingAuthorization]).shouldPulse(reduceMotion: false))
}

@Test func menuBarAttentionStopsPulseEvenWhenAnotherConnectionIsBusy() {
  let status = MenuBarStatusSummary(states: [.needsLogin, .connecting, .failed("example")])
  #expect(status.attention == 2)
  #expect(!status.shouldPulse(reduceMotion: false))
}

@Test func menuBarBusyPulseAlternatesEvenWhenAnotherShareIsMounted() {
  let status = MenuBarStatusSummary(states: [.connecting, .mounted(MountedShare(url: URL(filePath: "/tmp/demo")))])
  #expect(status.symbol(pulse: false) == "externaldrive")
  #expect(status.symbol(pulse: true) == "externaldrive.fill")
  let mounted = MenuBarStatusSummary(states: [.mounted(MountedShare(url: URL(filePath: "/tmp/demo")))])
  #expect(mounted.symbol(pulse: false) == "externaldrive.fill")
}
