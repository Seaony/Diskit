import Core
import SwiftUI

struct UpdateSettingsSection: View {
  @Bindable var updater: UpdateController

  var body: some View {
    KayoiFormSection(title: L("更新")) {
      Toggle(
        L("自动检查更新"),
        isOn: Binding(
          get: { updater.automaticallyChecksForUpdates },
          set: { updater.setAutomaticallyChecksForUpdates($0) }))
      Toggle(
        L("自动下载并安装"),
        isOn: Binding(
          get: { updater.automaticallyDownloadsUpdates },
          set: { updater.setAutomaticallyDownloadsUpdates($0) })
      )
      .disabled(!updater.allowsAutomaticUpdates)
      .help(updater.allowsAutomaticUpdates ? L("发现更新后自动下载安装") : L("此版本暂不支持自动安装更新"))
    }
  }
}

// 关于页里的检查更新和显示日志：按钮下面一行写上次检查时间或检查结果
struct UpdateCheckView: View {
  @Bindable var updater: UpdateController
  let showLogs: () -> Void

  var body: some View {
    VStack(spacing: Space.sm) {
      HStack(spacing: Space.sm) {
        Button(L("检查更新")) { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
        Button(L("显示日志"), action: showLogs)
      }
      Group {
        if let message = updater.message {
          Text(message)
        } else if let date = updater.lastUpdateCheckDate {
          Text(L("上次检查")) + Text(verbatim: " ") + Text(date, format: .dateTime.year().month().day().hour().minute())
        } else {
          Text(L("尚未检查"))
        }
      }
      .font(.caption).monospacedDigit().foregroundStyle(KayoiTheme.secondaryText)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
  }
}
