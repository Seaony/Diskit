import AppKit

// 设置里的界面语言。写进本 App 的 AppleLanguages，和系统“按 App 设置语言”是同一个设置；
// 文案在启动时加载，所以重新打开 Diskit 后生效
enum AppLanguage: String, CaseIterable, Identifiable {
  case system, chinese = "zh-Hans", english = "en"
  private static let key = "AppleLanguages"
  var id: String { rawValue }

  // 语言名用各自的文字写，不跟着界面语言翻译
  var title: String {
    switch self {
    case .system: L("跟随系统")
    case .chinese: "中文"
    case .english: "English"
    }
  }

  var symbol: String {
    switch self {
    case .system: "globe"
    case .chinese: "character.book.closed.zh"
    case .english: "character.book.closed"
    }
  }

  // 只看本 App 自己的设置，不看系统全局的语言列表
  static var saved: AppLanguage {
    let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
    guard let first = (domain?[key] as? [String])?.first else { return .system }
    if first.hasPrefix("zh") { return .chinese }
    if first.hasPrefix("en") { return .english }
    return .system
  }

  // 本次运行开始时的选择，用来判断是否需要重新打开；启动时就会读一次
  static let atLaunch = saved

  func save() {
    if self == .system {
      UserDefaults.standard.removeObject(forKey: Self.key)
    } else {
      UserDefaults.standard.set([rawValue], forKey: Self.key)
    }
  }

  // 等当前进程完全退出后再打开，避免两个 Diskit 同时在菜单栏
  @MainActor static func relaunch() {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [
      "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
      Bundle.main.bundleURL.path,
    ]
    guard (try? process.run()) != nil else { return }
    NSApplication.shared.terminate(nil)
  }
}
