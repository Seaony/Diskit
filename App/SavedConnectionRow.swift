import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

struct SavedConnectionRow: View {
  let connection: Connection
  let state: ConnectionState
  let errorDetail: String?
  var capabilities: ProviderCapabilities? = nil
  let isDemo: Bool
  let dragSource: PanelDraggingSource
  let selected: Bool
  var rowFocus: FocusState<UUID?>.Binding
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onSelect: () -> Void
  let onPrimary: () -> Void
  let onActivate: () -> Void
  let onEdit: () -> Void
  let onReauthenticate: () -> Void
  let onMove: (Int) -> Void
  let onDelete: () -> Void
  @Binding var draggedID: UUID?
  @Binding var dropTargetID: UUID?
  let onDrop: (UUID) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  @FocusState private var focusedAction: Action?
  private enum Action: Hashable { case copyDetails }
  @State private var showsError = false

  var body: some View {
    VStack(spacing: Space.sm) {
      TypeIcon(kind: connection.kind, color: connection.color, size: 36)
        .overlay(alignment: .bottomTrailing) { statusBadge.offset(x: 4, y: 4) } // grid: ok 角标压在图标右下角
        .overlay {
          PanelDragHandle(id: connection.id, name: connection.name, source: dragSource, draggedID: $draggedID)
        }
        .gridProbe("icon", area: "saved-" + connection.id.uuidString, edge: nil)
      Text(connection.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
        .foregroundStyle(KayoiTheme.primaryText)
        .gridProbe("text", area: "saved-" + connection.id.uuidString, edge: nil)
    }
    .padding(Space.md)
    .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92)
    .gridArea("saved-" + connection.id.uuidString, inset: Space.md)
    .background(cardFill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    // 落点：目标卡片左侧一条细插入线
    .overlay(alignment: .leading) {
      if draggedID != nil && dropTargetID == connection.id {
        Capsule().fill(KayoiTheme.primaryText.opacity(0.3)).frame(width: 2).padding(.vertical, Space.sm)
          .offset(x: -Space.sm + 1) // grid: ok 插入线落在两张卡片之间
      }
    }
    .popover(isPresented: $showsError) { errorDetails }
    .help(hoverText)
    .opacity(draggedID == connection.id ? 0.35 : 1)
    .scaleEffect(!reduceMotion && draggedID == connection.id ? 0.96 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargetID)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: draggedID)
    .onHover { hovering = $0 }
    .onContinuousHover { phase in
      switch phase {
      case .active: NSCursor.pointingHand.set()
      case .ended: NSCursor.arrow.set()
      }
    }
    .focusable().focusEffectDisabled()
    .focused(rowFocus, equals: connection.id)
    .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    .onTapGesture(perform: activate)
    .onDrop(of: [.text], delegate: PanelDropDelegate(source: $draggedID, target: $dropTargetID, destination: connection.id) { source, _ in onDrop(source) })
    .contextMenu {
      if ProviderAccess.isReadOnly(capabilities) {
        Text(L("这个位置只能读取"))
        Divider()
      }
      if case .mounted(let mounted) = state {
        Button(L("在 Finder 中打开")) { if !isDemo { NSWorkspace.shared.open(mounted.url) } }
        Button(L("推出"), action: onPrimary)
        Button(L("复制路径")) { copy(mounted.url.path) }
      } else if state == .connecting || state == .awaitingAuthorization {
        Button(L("取消"), action: onPrimary)
      } else if state != .ejecting && state != .unavailable {
        Button(PanelCopy.buttonTitle(state, kind: connection.kind), action: onPrimary)
      }
      if case .failed = state { Button(L("查看错误详情")) { showsError = true } }
      if connection.kind.isCloud && state != .needsLogin { Button(L("重新登录"), action: onReauthenticate) }
      Divider()
      Button(L("编辑…"), action: onEdit)
      if canMoveUp { Button(L("上移")) { onMove(-1) } }
      if canMoveDown { Button(L("下移")) { onMove(1) } }
      Divider()
      Button(L("删除…"), role: .destructive, action: onDelete)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel([connection.name, connection.kind.title, PanelCopy.subtitle(state, kind: connection.kind)].joined(separator: "，"))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction { activate() }
  }

  // 状态角标：进行中转圈，其它用小圆点，未连接不显示
  @ViewBuilder private var statusBadge: some View {
    if state == .connecting || state == .awaitingAuthorization || state == .ejecting {
      ProgressView().nativeProgressAppearance().controlSize(.mini)
        .frame(width: 14, height: 14)
        .background(cardFill, in: Circle())
    } else if let color = badgeColor {
      Circle().fill(color).frame(width: 10, height: 10)
        .padding(2) // grid: ok 圆点外圈用卡片底色隔开图标
        .background(cardFill, in: Circle())
    }
  }

  private var badgeColor: Color? {
    switch state {
    case .mounted, .tested: KayoiTheme.accent
    case .needsLogin: KayoiTheme.warning
    case .failed: KayoiTheme.error
    case .unavailable: KayoiTheme.secondaryText
    default: nil
    }
  }

  private func activate() {
    onSelect()
    onActivate()
  }

  private var hoverText: String {
    let status = PanelCopy.subtitle(state, kind: connection.kind)
    let hint: String? =
      switch state {
      case .mounted: L("点按在 Finder 中打开")
      case .connecting, .awaitingAuthorization, .ejecting, .unavailable: nil
      default: LF("点按：%@", PanelCopy.buttonTitle(state, kind: connection.kind))
      }
    return ([connection.name, status] + [hint].compactMap { $0 } + [L("拖动图标调整顺序")]).joined(separator: "\n")
  }

  private var cardFill: Color {
    selected ? KayoiTheme.selection : hovering ? KayoiTheme.hover : KayoiTheme.surface
  }

  private var errorDetails: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(L("无法连接")).font(.headline)
      ScrollView { Text(fullSubtitle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
      Text(ConnectionFailureAdvice.text(for: connection.kind))
        .font(.caption).foregroundStyle(KayoiTheme.secondaryText)
      Button(L("复制详细信息")) { copy(fullSubtitle) }
        .buttonStyle(FlatButtonStyle(focusOverride: focusedAction == .copyDetails))
        .focused($focusedAction, equals: .copyDetails)
    }.padding(Space.lg).frame(width: 300).background(KayoiTheme.surface)
  }

  private var fullSubtitle: String { errorDetail ?? PanelCopy.subtitle(state, kind: connection.kind) }
  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
