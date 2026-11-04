import Core
import SwiftUI

struct UpdateSettingsSection: View {
  @Bindable var updater: UpdateController

  var body: some View {
    Section {
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
      Button(L("检查更新…")) { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
      LabeledContent(L("上次检查")) {
        if let date = updater.lastUpdateCheckDate {
          Text(date, format: .dateTime.year().month().day().hour().minute())
            .monospacedDigit().foregroundStyle(KayoiTheme.secondaryText)
        } else {
          Text(L("尚未检查")).foregroundStyle(KayoiTheme.secondaryText)
        }
      }
      if let message = updater.message {
        Text(message).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text(L("更新"))
    }
  }
}
