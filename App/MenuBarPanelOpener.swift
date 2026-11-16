import AppKit
import OSLog

// 苹果没有用代码打开菜单栏下拉面板的接口：找到 Diskit 的菜单栏图标，看得见就替用户打开它下面的面板。
// 做法参考开源库 MenuBarExtraAccess（MIT 许可，github.com/orchetect/MenuBarExtraAccess）。
// 图标被刘海挡住或被系统隐藏时返回 false，由调用方改开独立窗口。
@MainActor enum MenuBarPanelOpener {
  private static let logger = Logger(subsystem: "com.seaony.Diskit", category: "panel")
  private static let beginSession = NSSelectorFromString("_beginExpandedInterfaceSession:")
  private static let session = NSSelectorFromString("expandedInterfaceSession")

  static func open() -> Bool {
    // 面板已经开着：再打开一次会把它关掉，只把它提到前面
    if let panel = NSApp.windows.first(where: { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }) {
      NSApp.activate()
      panel.makeKeyAndOrderFront(nil)
      return true
    }
    // 每块显示器各有一个图标窗口；真正的图标对象只有一个（macOS 26 起类名是 NSSceneStatusItem），其余是系统复制出来的
    let windows = NSApp.windows.filter { $0.className == "NSStatusBarWindow" }
    // 私有属性：系统改名后直接读会崩溃，先确认有这个属性
    guard let item = windows.lazy.filter({ $0.responds(to: NSSelectorFromString("statusItem")) })
      .compactMap({ $0.value(forKey: "statusItem") as? NSStatusItem })
      .first(where: { $0.className == "NSSceneStatusItem" })
    else {
      logger.notice("没找到菜单栏图标，改开面板窗口")
      return false
    }
    let shown = windows.contains { window in
      guard window.isVisible, let screen = window.screen else { return false }
      return MenuBarIconPlacement.isShown(window.frame, screen: screen.frame, notchLeft: screen.auxiliaryTopLeftArea, notchRight: screen.auxiliaryTopRightArea)
    }
    logger.info("菜单栏图标 frames=\(windows.map { NSStringFromRect($0.frame) }.joined(separator: " "), privacy: .public) shown=\(shown)")
    guard shown else { return false }
    NSApp.activate()
    present(item)
    return true
  }

  private static func present(_ item: NSStatusItem) {
    // macOS 27 起面板改由系统内部的“展开界面会话”打开，模拟点击按钮不再起作用。
    // 时间戳传最大值：系统会丢掉早于上次关闭的打开请求，用代码打开没有对应的点击事件。
    if item.responds(to: beginSession), item.responds(to: session), let implementation = item.method(for: beginSession) {
      guard item.perform(session)?.takeUnretainedValue() == nil else { return }
      typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
      unsafeBitCast(implementation, to: Begin.self)(item, beginSession, .greatestFiniteMagnitude)
      return
    }
    // macOS 26：按钮的点击动作就是打开面板
    item.button?.performClick(nil)
  }
}
