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
  let dropDisplacement: CGFloat
  let dropDelay: Double
  let selected: Bool
  var rowFocus: FocusState<UUID?>.Binding
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onSelect: () -> Void
  let onPrimary: () -> Void
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
  private enum Action: Hashable { case primary, details, copyDetails }
  @State private var showsError = false

  var body: some View {
    HStack(spacing: Space.md) {
      TypeIcon(kind: connection.kind, color: connection.color, size: 28)
        .gridProbe("icon", area: "saved-" + connection.id.uuidString, edge: nil)
        .overlay {
          PanelDragHandle(id: connection.id, name: connection.name, source: dragSource, draggedID: $draggedID)
        }
        .help(L("拖动以调整顺序"))
      VStack(alignment: .leading, spacing: Space.xs) {
        HStack(spacing: Space.xs) {
          Text(connection.name).font(.body).lineLimit(1).help(connection.name)
          if ProviderAccess.isReadOnly(capabilities) {
            Text(L("只读")).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
              .fixedSize().help(L("这个位置只能读取"))
          }
        }
        HStack(alignment: .top, spacing: Space.xs) {
          if case .tested = state { Image(systemName: "checkmark.circle.fill") }
          if case .mounted = state { Image(systemName: "circle.fill").imageScale(.small) }
          Text(PanelCopy.subtitle(state, kind: connection.kind)).lineLimit(2)
            .help(fullSubtitle)
        }.font(.caption).foregroundStyle(statusColor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .gridProbe("text", area: "saved-" + connection.id.uuidString, edge: nil)
      .contentShape(Rectangle())
      .onTapGesture {
        onSelect()
        if case .mounted(let mounted) = state { if !isDemo { NSWorkspace.shared.open(mounted.url) } }
      }
      if state == .connecting || state == .ejecting {
        ProgressView().nativeProgressAppearance().controlSize(.mini).accessibilityLabel(PanelCopy.subtitle(state, kind: connection.kind))
      }
      if state != .ejecting {
        Button(action: onPrimary) {
          if state == .connecting {
            Image(systemName: "xmark")
          } else {
            Text(PanelCopy.buttonTitle(state, kind: connection.kind))
          }
        }
        .buttonStyle(FlatButtonStyle(focusOverride: focusedAction == .primary))
        .focused($focusedAction, equals: .primary)
        .fixedSize()
        .disabled(state == .unavailable)
        .help(state == .unavailable ? PanelCopy.subtitle(state, kind: connection.kind) : PanelCopy.buttonTitle(state, kind: connection.kind))
        .accessibilityLabel(LF("%@“%@”", PanelCopy.buttonTitle(state, kind: connection.kind), connection.name))
      }
      if case .failed = state {
        Button { showsError = true } label: { Image(systemName: "info.circle") }
          .buttonStyle(FlatIconButtonStyle(focusOverride: focusedAction == .details))
          .focused($focusedAction, equals: .details).help(L("查看错误详情"))
          .accessibilityLabel(L("查看错误详情"))
          .popover(isPresented: $showsError) {
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
      }
    }
    .padding(.horizontal, Space.sm).padding(.vertical, Space.xs).frame(minHeight: 52)
    .gridArea("saved-" + connection.id.uuidString, inset: Space.sm)
    .background(hovering ? KayoiTheme.hover : KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(selected ? KayoiTheme.focus : KayoiTheme.border, lineWidth: selected ? 2 : 1) }
    .overlay(alignment: .top) {
      if draggedID != nil && dropTargetID == connection.id {
        Rectangle().fill(KayoiTheme.primaryText.opacity(0.15)).frame(height: 1).padding(.horizontal, 8)
      }
    }
    .offset(y: dropDisplacement) // grid: ok 按下或拖动时的短暂位移
    .scaleEffect(!reduceMotion && draggedID == connection.id ? 0.96 : 1)
    .opacity(!reduceMotion && draggedID == connection.id ? 0 : 1)
    .frame(height: draggedID == connection.id && !reduceMotion ? 0 : nil)
    .clipped()
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12).delay(dropDelay), value: dropTargetID)
    .onHover { hovering = $0 }
    .onContinuousHover { phase in
      switch phase {
      case .active: NSCursor.pointingHand.set()
      case .ended: NSCursor.arrow.set()
      }
    }
    .focusable().focusEffectDisabled()
    .focused(rowFocus, equals: connection.id)
    .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    .onTapGesture(perform: onSelect)
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
      } else if state != .connecting && state != .awaitingAuthorization && state != .ejecting && state != .unavailable {
        Button(L("测试连接"), action: onPrimary)
      }
      if connection.kind.isCloud { Button(L("重新登录"), action: onReauthenticate) }
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
  }

  private var fullSubtitle: String { errorDetail ?? PanelCopy.subtitle(state, kind: connection.kind) }
  private var statusColor: Color {
    switch state {
    case .failed: KayoiTheme.error
    case .needsLogin: KayoiTheme.warning
    case .mounted: KayoiTheme.accent
    default: KayoiTheme.secondaryText
    }
  }
  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
