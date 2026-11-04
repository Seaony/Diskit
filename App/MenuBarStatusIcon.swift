import Core
import SwiftUI

struct MenuBarStatusIcon: View {
  let states: [ConnectionState]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var pulse = false
  private var status: MenuBarStatusSummary { MenuBarStatusSummary(states: states) }
  private var shouldPulse: Bool { status.shouldPulse(reduceMotion: reduceMotion) }

  private var label: String {
    if status.attention > 0 { return LF("Kayoi，%d 个位置需要处理", status.attention) }
    if status.busy { return L("Kayoi，正在连接位置") }
    if status.mounted > 0 { return LF("Kayoi，%d 个位置已挂载", status.mounted) }
    return L("Kayoi，没有挂载的位置")
  }

  var body: some View {
    Image(systemName: status.symbol(pulse: pulse))
      .renderingMode(.template)
      .frame(width: 20, height: 20)
      .overlay(alignment: .bottomTrailing) {
        if status.attention > 0 {
          Circle().fill(KayoiTheme.warning).frame(width: 4, height: 4)
        } else if status.mounted > 0 {
          Circle().fill(KayoiTheme.accent).frame(width: 4, height: 4)
        }
      }
      .transaction { $0.animation = nil }
      .task(id: shouldPulse) {
        if pulse { pulse = false }
        guard shouldPulse else { return }
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
          guard !Task.isCancelled else { return }
          pulse.toggle()
        }
      }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .help(label)
  }
}

#Preview("菜单栏 · 空状态") { MenuBarStatusIcon(states: []).padding().preferredColorScheme(.light) }
#Preview("菜单栏 · 连接中") { MenuBarStatusIcon(states: [.connecting]).padding().preferredColorScheme(.light) }
#Preview("菜单栏 · 需要处理 · 深色") { MenuBarStatusIcon(states: [.needsLogin]).padding().preferredColorScheme(.dark) }
