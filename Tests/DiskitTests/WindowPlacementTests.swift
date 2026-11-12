import CoreGraphics
import Foundation
import Testing

@Test func windowsReturnFromDisconnectedDisplayWithoutLeavingScreen() {
  let main = CGRect(x: 0, y: 24, width: 1470, height: 900)
  let lost = CGRect(x: 2200, y: 400, width: 760, height: 600)
  let restored = WindowPlacement.visibleFrame(lost, screens: [main], preferred: main)
  #expect(main.contains(restored))
  #expect(restored.size == lost.size)
}

@Test func windowRecoveryPreservesValidSecondaryAndNegativeCoordinates() {
  let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
  let main = CGRect(x: 0, y: 24, width: 1470, height: 900)
  let existing = CGRect(x: -1500, y: 200, width: 640, height: 640)
  #expect(
    WindowPlacement.visibleFrame(existing, screens: [left, main], preferred: main) == existing)
  let lost = CGRect(x: 2400, y: 500, width: 640, height: 640)
  #expect(
    left.contains(WindowPlacement.visibleFrame(lost, screens: [left, main], preferred: left)))
}

@Test func oversizedWindowRecoveryKeepsTitleAndContentReachable() {
  let screen = CGRect(x: 0, y: 24, width: 1280, height: 700)
  let oversized = CGRect(x: -100, y: -100, width: 2000, height: 1400)
  #expect(WindowPlacement.visibleFrame(oversized, screens: [screen], preferred: screen) == screen)
  #expect(WindowPlacement.visibleFrame(oversized, screens: [], preferred: nil) == oversized)
}
