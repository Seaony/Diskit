import Core
import SwiftUI

struct HelpGuideDetail: View {
  let guide: HelpGuide

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.section) {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text(guide.kind.title).font(.title2.bold())
            .gridProbe("guide-title", area: "help-detail", edge: nil)
          Text(guide.introduction)
            .font(.body)
            .foregroundStyle(KayoiTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !guide.kind.usesSystemMount {
          Label {
            Text(L("本版本可测试连接，尚不提供此类型的 Finder 挂载。"))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "info.circle").accessibilityHidden(true)
          }
          .font(.callout)
          .foregroundStyle(KayoiTheme.secondaryText)
        }

        VStack(alignment: .leading, spacing: Space.md) {
          Text(L("准备步骤")).font(.headline)
          ForEach(guide.steps) { step in
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
              Image(systemName: "circle.fill")
                .font(.caption2)
                .imageScale(.small)
                .frame(width: Space.sm)
                .accessibilityHidden(true)
              Text(step.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }.gridProbe("steps", area: "help-detail")

        VStack(alignment: .leading, spacing: Space.md) {
          Text(L("位置能力")).font(.headline)
          if !guide.kind.usesSystemMount {
            Text(L("以下文件操作目前需通过命令行工具 kayoi-dev 使用。"))
              .font(.callout)
              .foregroundStyle(KayoiTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
          Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
            ForEach(guide.capabilities) { capability in
              GridRow {
                Text(capability.title)
                Label(capability.availability.title, systemImage: capability.availability.symbol)
                  .foregroundStyle(KayoiTheme.secondaryText)
                  .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
          .font(.body)
          if guide.kind == .ricohGR || guide.kind == .cameraUSB {
            Text(L("能否删除由相机决定；不支持时不会发送删除请求。相机位置不能上传、改名或移动文件。"))
              .font(.caption)
              .foregroundStyle(KayoiTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.gridProbe("capabilities", area: "help-detail")

        VStack(alignment: .leading, spacing: Space.md) {
          Text(L("常见问题")).font(.headline)
          ForEach(guide.questions) { question in
            DisclosureGroup {
              Text(question.answer)
                .font(.body)
                .foregroundStyle(KayoiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.sm)
            } label: {
              Text(question.title).font(.body)
            }
          }
        }.gridProbe("questions", area: "help-detail")

        Text(L("文件仍保存在你选择的设备或服务中。删除前请确认操作后果，并保留重要文件的备份。"))
          .font(.caption)
          .foregroundStyle(KayoiTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 680, alignment: .leading)
      .padding(Space.margin)
      .gridArea("help-detail", inset: Space.margin)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(KayoiTheme.primaryText)
      .textSelection(.enabled)
    }
    .background(KayoiTheme.background)
    .gridDiagnostics("help")
  }
}

#Preview("帮助详情 · 浅色") {
  HelpGuideDetail(guide: HelpGuide.all[0]).frame(width: 520, height: 600).preferredColorScheme(.light)
}
#Preview("帮助详情 · 深色") {
  HelpGuideDetail(guide: HelpGuide.all[0]).frame(width: 520, height: 600).preferredColorScheme(.dark)
}
