import AppKit
import Darwin
import SwiftUI

@MainActor final class DemoPerformanceProbe {
  private var timeline: PerformanceTimeline
  private let output: URL
  private let writer = DispatchQueue(label: "com.seaony.Kayoi.demo-performance", qos: .utility)

  init?(options: RuntimeOptions) {
    guard let path = options.performanceOutput else { return nil }
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
      }
    }
    guard result == 0, usage.ri_proc_start_abstime > 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
    timeline = PerformanceTimeline(
      processID: getpid(), processStartTick: usage.ri_proc_start_abstime,
      nanosecondsPerTick: Double(timebase.numer) / Double(timebase.denom))
    output = URL(filePath: path)
  }

  func requestPanel() {
    timeline.requestPanel(at: mach_absolute_time())
    writeSnapshot()
  }

  func needsDraw(role: PerformanceDrawProbe.Role) -> Bool {
    role == .menu ? timeline.needsMenuDraw : timeline.needsPanelDraw
  }

  func didDraw(role: PerformanceDrawProbe.Role) {
    let tick = mach_absolute_time()
    let changed = role == .menu ? timeline.drewMenu(at: tick) : timeline.drewPanel(at: tick)
    if changed { writeSnapshot() }
  }

  private func writeSnapshot() {
    let snapshot = timeline
    let output = output
    writer.async {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: output, options: .atomic)
      } catch {
        NSLog("演示性能记录写入失败：%@", error.localizedDescription)
      }
    }
  }
}

struct PerformanceDrawProbe: NSViewRepresentable {
  enum Role { case menu, panel }
  let probe: DemoPerformanceProbe
  let role: Role

  func makeNSView(context: Context) -> DrawView {
    let view = DrawView()
    view.probe = probe
    view.role = role
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ view: DrawView, context: Context) {}

  @MainActor final class DrawView: NSView {
    weak var probe: DemoPerformanceProbe?
    var role: Role = .menu
    private var completionQueued = false
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard !completionQueued, probe?.needsDraw(role: role) == true,
        let window, window.isVisible, !isHiddenOrHasHiddenAncestor
      else {
        return
      }
      completionQueued = true
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self else { return }
        completionQueued = false
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }
        probe?.didDraw(role: role)
      }
    }
  }
}
