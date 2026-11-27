import ADB
import AppKit

// Android File Transfer 开着时独占安卓设备的文件传输接口，插上设备时它的登录项还会自动打开它。
// Diskit 连文件传输设备被它挡住时，让它正常退出，再由 Diskit 连接
@MainActor enum AndroidFileTransfer {
  static let bundleID = "com.google.android.mtpviewer"

  private static var running: [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
  }

  static func quitIfRunning() async {
    let apps = running
    guard !apps.isEmpty else { return }
    for app in apps { app.terminate() }
    // 进程真正退出后系统才放开接口，最多等 3 秒
    for _ in 0..<30 where !apps.allSatisfy(\.isTerminated) {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  // 先直接连；连不上且它正占着文件传输接口，才让它退出再连一次。没挡着时（比如设备锁屏没回应）不去动它。
  // 连接期间 Diskit 自己也不去问设备型号，免得和连接抢接口
  static func connecting<Value>(_ body: () async throws -> Value) async throws -> Value {
    try await MTPDiscovery.connecting {
      do {
        return try await body()
      } catch {
        guard !(error is CancellationError), !running.isEmpty, MTPUSB.heldByAndroidFileTransfer()
        else { throw error }
        await quitIfRunning()
        return try await body()
      }
    }
  }
}
