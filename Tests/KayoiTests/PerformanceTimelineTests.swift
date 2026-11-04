import Foundation
import Testing

@Test func performanceOutputRequiresDemoAndExplicitAbsolutePath() {
  #expect(
    RuntimeOptions(environment: ["KAYOI_PERF_OUTPUT": "/tmp/local.json"]).performanceOutput == nil)
  #expect(RuntimeOptions(environment: ["KAYOI_DEMO": "1"]).performanceOutput == nil)
  #expect(
    RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_PERF_OUTPUT": "relative.json"])
      .performanceOutput == nil)
  #expect(
    RuntimeOptions(environment: ["KAYOI_DEMO": "1", "KAYOI_PERF_OUTPUT": "/tmp/local.json"])
      .performanceOutput == "/tmp/local.json")
}

@Test func menuReadinessUsesProcessClockAndOnlyRecordsOnce() throws {
  var timeline = PerformanceTimeline(processID: 1, processStartTick: 10, nanosecondsPerTick: 100)
  let drewMenuAt9 = timeline.drewMenu(at: 9)
  #expect(!drewMenuAt9)
  let drewMenuAt110 = timeline.drewMenu(at: 110)
  #expect(drewMenuAt110)
  let drewMenuAt210 = timeline.drewMenu(at: 210)
  #expect(!drewMenuAt210)
  #expect(!timeline.needsMenuDraw && timeline.events.count == 1)
  #expect(timeline.events[0].elapsedMilliseconds == 0.01)
  let json = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any])
  #expect(json["processStartTick"] as? Int == 10)
  #expect(json["measurementBoundary"] as? String == timeline.measurementBoundary)
}

@Test func panelReadinessRequiresAnOpenRequestAndRearmsForNextOpen() {
  var timeline = PerformanceTimeline(
    processID: 1, processStartTick: 10, nanosecondsPerTick: 1_000_000)
  let drewPanelAt100 = timeline.drewPanel(at: 100)
  #expect(!drewPanelAt100)
  timeline.requestPanel(at: 110)
  #expect(timeline.needsPanelDraw)
  let drewPanelAt109 = timeline.drewPanel(at: 109)
  #expect(!drewPanelAt109)
  let drewPanelAt125 = timeline.drewPanel(at: 125)
  #expect(drewPanelAt125)
  let drewPanelAt140 = timeline.drewPanel(at: 140)
  #expect(!drewPanelAt140)
  #expect(timeline.events.last?.elapsedMilliseconds == 15)
  timeline.requestPanel(at: 200)
  let drewPanelAt220 = timeline.drewPanel(at: 220)
  #expect(drewPanelAt220)
  #expect(timeline.events.last?.elapsedMilliseconds == 20)
  #expect(timeline.events.count == 4 && !timeline.needsPanelDraw)
}
