import Core
import SwiftUI

private struct PanelDemoPreview: View {
  @State private var model: AppModel
  init(scenario: String) {
    _model = State(initialValue: AppModel(options: RuntimeOptions(environment: [
      "KAYOI_DEMO": "1", "KAYOI_DEMO_STATE": scenario,
    ])))
  }
  var body: some View { PanelView(model: model) }
}

private struct PanelRowPreview: View {
  let state: ConnectionState
  let connection: Connection
  @FocusState private var focus: UUID?
  @State private var draggedID: UUID?
  @State private var dropTargetID: UUID?
  @State private var dragSource = PanelDraggingSource()

  init(_ state: ConnectionState, kind: ConnectionKind = .androidUSB) {
    self.state = state
    connection = Connection(kind: kind, name: "我的位置", color: "blue")
  }

  var body: some View {
    SavedConnectionRow(
      connection: connection, state: state, errorDetail: nil, isDemo: true, dragSource: dragSource,
      dropDisplacement: 0, dropDelay: 0, selected: focus == connection.id,
      rowFocus: $focus, canMoveUp: true, canMoveDown: true,
      onSelect: { focus = connection.id }, onPrimary: {}, onEdit: {},
      onReauthenticate: {}, onMove: { _ in }, onDelete: {},
      draggedID: $draggedID, dropTargetID: $dropTargetID, onDrop: { _ in }
    ).padding(Space.lg).frame(width: 380).background(KayoiTheme.background)
  }
}

#Preview("面板 · 浅色") { PanelDemoPreview(scenario: "mixed").preferredColorScheme(.light) }
#Preview("面板 · 深色") { PanelDemoPreview(scenario: "mixed").preferredColorScheme(.dark) }
#Preview("面板 · 空状态 · 浅色") { PanelDemoPreview(scenario: "empty").preferredColorScheme(.light) }
#Preview("面板 · 空状态 · 深色") { PanelDemoPreview(scenario: "empty").preferredColorScheme(.dark) }
#Preview("面板 · 只有发现") { PanelDemoPreview(scenario: "discovered") }
#Preview("位置 · 未连接") { PanelRowPreview(.disconnected) }
#Preview("位置 · 设备未连接") { PanelRowPreview(.unavailable) }
#Preview("位置 · 连接中") { PanelRowPreview(.connecting) }
#Preview("位置 · 等待授权") { PanelRowPreview(.awaitingAuthorization) }
#Preview("位置 · 已连接") {
  PanelRowPreview(.tested(SpaceInfo(total: 256_000_000_000, used: 136_000_000_000)))
}
#Preview("位置 · 已挂载") {
  PanelRowPreview(.mounted(MountedShare(url: URL(filePath: "/tmp/KayoiDemo"), availableBytes: 120_000_000_000)), kind: .smb)
}
#Preview("位置 · 推出中") { PanelRowPreview(.ejecting, kind: .smb) }
#Preview("位置 · 失败") { PanelRowPreview(.failed(L("用户名或密码错误，请检查后重试"))) }
#Preview("位置 · 登录过期") { PanelRowPreview(.needsLogin, kind: .aliyunDrive) }
