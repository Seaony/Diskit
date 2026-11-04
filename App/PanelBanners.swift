import SwiftUI

struct PanelDiscoveryBanner: View {
  let message: String
  let permissionDenied: Bool
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: Space.sm) {
      Image(systemName: "wifi.exclamationmark").foregroundStyle(KayoiTheme.warning)
        .frame(width: Space.lg)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Space.sm) {
        Text(message).font(.caption).foregroundStyle(KayoiTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
        Button(permissionDenied ? L("打开本地网络设置") : L("添加位置"), action: action)
          .buttonStyle(FlatButtonStyle())
      }.frame(maxWidth: .infinity, alignment: .leading)
        .gridProbe("message", area: "discovery-banner-" + message, edge: nil)
    }
    .padding(Space.md)
    .gridArea("discovery-banner-" + message, inset: Space.md)
    .background(KayoiTheme.warningBackground, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(KayoiTheme.warning) }
  }
}

struct PanelFailureBanner: View {
  let title: String
  let message: String
  var body: some View {
    HStack(alignment: .top, spacing: Space.sm) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(KayoiTheme.error)
        .frame(width: Space.lg)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(message).font(.caption).textSelection(.enabled)
      }.foregroundStyle(KayoiTheme.error)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridProbe("message", area: "failure-banner-" + title, edge: nil)
    }.padding(Space.md)
      .gridArea("failure-banner-" + title, inset: Space.md)
      .background(KayoiTheme.errorBackground, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
  }
}

#Preview("发现错误 · 权限") {
  PanelDiscoveryBanner(message: L("请允许 Kayoi 访问本地网络"), permissionDenied: true, action: {}).padding().frame(width: 380)
}
#Preview("发现错误 · 网络") {
  PanelDiscoveryBanner(message: L("暂时无法发现局域网设备，请检查网络连接"), permissionDenied: false, action: {}).padding().frame(width: 380)
}
#Preview("发现错误 · USB") {
  PanelDiscoveryBanner(message: L("暂时无法发现 USB 手机，请重新插拔设备"), permissionDenied: false, action: {}).padding().frame(width: 380)
}
#Preview("发现错误 · 理光相机") {
  PanelDiscoveryBanner(message: L("暂时无法发现理光相机，请检查 USB 连接"), permissionDenied: false, action: {}).padding().frame(width: 380)
}
#Preview("发现错误 · 相机") {
  PanelDiscoveryBanner(message: L("暂时无法发现相机，请检查 USB 连接"), permissionDenied: false, action: {}).padding().frame(width: 380)
}
#Preview("读取错误") {
  PanelFailureBanner(title: L("无法读取位置列表"), message: L("文件无法读取，请检查访问权限")).padding().frame(width: 380)
}

#Preview("发现错误 · 深色") {
  PanelDiscoveryBanner(message: L("请允许 Kayoi 访问本地网络"), permissionDenied: true, action: {})
    .padding().frame(width: 380).preferredColorScheme(.dark)
}
#Preview("读取错误 · 深色") {
  PanelFailureBanner(title: L("无法读取位置列表"), message: L("文件无法读取，请检查访问权限"))
    .padding().frame(width: 380).preferredColorScheme(.dark)
}
