import Core
import Foundation
import Testing

@Test func menuBarIdleAndReducedMotionNeverRequestPulse() {
  #expect(!MenuBarStatusSummary(states: []).shouldPulse(reduceMotion: false))
  #expect(!MenuBarStatusSummary(states: [.connecting]).shouldPulse(reduceMotion: true))
  #expect(MenuBarStatusSummary(states: [.connecting]).shouldPulse(reduceMotion: false))
  #expect(MenuBarStatusSummary(states: [.awaitingAuthorization]).shouldPulse(reduceMotion: false))
  #expect(MenuBarStatusSummary(states: []).glyph(pulse: true, reduceMotion: false) == .dimmedGlyph)
}

@Test func menuBarAttentionOverlaysTheConnectingPulse() {
  let status = MenuBarStatusSummary(states: [.needsLogin, .connecting, .failed("example")])
  #expect(status.attention == 2)
  #expect(status.shouldPulse(reduceMotion: false))
  #expect(status.glyph(pulse: false, reduceMotion: false) == .glyph)
  #expect(status.glyph(pulse: true, reduceMotion: false) == .filled)
}

@Test func menuBarBusyPulseAlternatesEvenWhenAnotherShareIsMounted() {
  let status = MenuBarStatusSummary(states: [
    .connecting, .mounted(MountedShare(url: URL(filePath: "/tmp/demo"))),
  ])
  #expect(status.glyph(pulse: false, reduceMotion: false) == .glyph)
  #expect(status.glyph(pulse: true, reduceMotion: false) == .filled)
  let mounted = MenuBarStatusSummary(states: [
    .mounted(MountedShare(url: URL(filePath: "/tmp/demo")))
  ])
  #expect(mounted.glyph(pulse: false, reduceMotion: false) == .glyph)
  #expect(mounted.glyph(pulse: true, reduceMotion: true) == .glyph)
}

@Test func menuBarAttentionKeepsTheMountedAndUnmountedGlyphStates() {
  let unmounted = MenuBarStatusSummary(states: [.needsLogin])
  #expect(unmounted.attention == 1)
  #expect(unmounted.glyph(pulse: false, reduceMotion: false) == .dimmedGlyph)
  let mountedProblem = MenuBarStatusSummary(states: [
    .failed("x"), .mounted(MountedShare(url: URL(filePath: "/tmp/demo"))),
  ])
  #expect(mountedProblem.attention == 1)
  #expect(mountedProblem.glyph(pulse: true, reduceMotion: false) == .glyph)
}

@Test func menuBarReducedMotionKeepsConnectingGlyphStaticEvenWhenAlreadyMounted() {
  for connecting in [ConnectionState.connecting, .awaitingAuthorization] {
    let status = MenuBarStatusSummary(states: [
      connecting, .needsLogin, .mounted(MountedShare(url: URL(filePath: "/tmp/demo"))),
    ])
    #expect(!status.shouldPulse(reduceMotion: true))
    #expect(status.glyph(pulse: false, reduceMotion: true) == .glyph)
    #expect(status.glyph(pulse: true, reduceMotion: true) == .glyph)
  }
}
