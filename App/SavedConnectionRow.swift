import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

// 面板的两种排列：卡片网格或列表
enum PanelLayout: String {
  case grid, list
}

struct SavedConnectionRow: View {
  let connection: Connection
  let state: ConnectionState
  let errorDetail: String?
  var capabilities: ProviderCapabilities? = nil
  let isDemo: Bool
  let layout: PanelLayout
  // 列表里除第一行外，行顶有一条缩进的细分隔线
  var showsDivider = false
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

  var body: some View {
    Group {
      if layout == .grid { gridCard } else { listRow }
    }
    // 整张卡片接收点按（弹出操作菜单）、右键和拖动
    .overlay {
      PanelDragHandle(
        id: connection.id, source: dragSource, draggedID: $draggedID,
        toolTip: hoverText, menu: makeMenu, clicked: onSelect)
    }
    .overlay(alignment: layout == .grid ? .leading : .top) { insertionLine }
    .opacity(draggedID == connection.id ? 0.35 : 1)
    .scaleEffect(!reduceMotion && draggedID == connection.id ? 0.96 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargetID)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: draggedID)
    .onHover { hovering = $0 }
    .focusable().focusEffectDisabled()
    .focused(rowFocus, equals: connection.id)
    .onDrop(of: [.text], delegate: PanelDropDelegate(source: $draggedID, target: $dropTargetID, destination: connection.id) { source, _ in onDrop(source) })
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([connection.name, connection.kind.title, PanelCopy.subtitle(state, kind: connection.kind)].joined(separator: "，"))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { onActivate() }
    // 菜单只能用鼠标打开，旁白通过操作列表执行同样的菜单项
    .accessibilityActions {
      ForEach(Array(menuGroups.joined().enumerated()), id: \.offset) { _, entry in
        Button(entry.title, action: entry.action)
      }
    }
  }

  private var gridCard: some View {
    let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    return VStack(spacing: Space.sm) {
      PanelStatusIcon(kind: connection.kind, color: connection.color, size: 34, badge: badge, ring: fill)
        .gridProbe("icon", area: "saved-" + connection.id.uuidString, edge: nil)
      VStack(spacing: 2) { // grid: ok 与列表的标题副标题间距一致
        Text(connection.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
          .foregroundStyle(KayoiTheme.primaryText)
        Text(PanelCopy.cardCaption(state, kind: connection.kind)).font(.system(size: 9)).lineLimit(1)
          .foregroundStyle(captionColor)
      }
      .gridProbe("text", area: "saved-" + connection.id.uuidString, edge: nil)
    }
    .padding(.horizontal, 10) // grid: ok 设计稿卡片左右 10
    .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88)
    .gridArea("saved-" + connection.id.uuidString, inset: 10)
    .background(fill, in: shape)
    .overlay { shape.strokeBorder(KayoiTheme.border, lineWidth: 0.5) }
    // 出错和登录过期的底色盖住了选中色，选中时用描边标出
    .overlay { if selected && isIssue { shape.strokeBorder(KayoiTheme.focus, lineWidth: 2) } }
    .contentShape(shape)
  }

  private var listRow: some View {
    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
    return HStack(spacing: 10) { // grid: ok 设计稿图标与文字间距 10
      PanelStatusIcon(kind: connection.kind, color: connection.color, size: 34, badge: badge, ring: listFill ?? KayoiTheme.surface)
      VStack(alignment: .leading, spacing: 2) { // grid: ok 标题与副标题之间留一点
        Text(connection.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
          .foregroundStyle(KayoiTheme.primaryText)
        Text(PanelCopy.listCaption(state, kind: connection.kind, detail: errorDetail)).font(.system(size: 9)).lineLimit(1)
          .foregroundStyle(captionColor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Space.sm) // 列表行四周内边距一致
    .background(listFill ?? .clear, in: shape)
    .overlay(alignment: .top) {
      if showsDivider && listFill == nil {
        Rectangle().fill(KayoiTheme.border).frame(height: 0.5).padding(.leading, 52).padding(.trailing, Space.sm) // grid: ok 分隔线从文字处开始
      }
    }
    .overlay { if selected && isIssue { shape.strokeBorder(KayoiTheme.focus, lineWidth: 2) } }
    .contentShape(shape)
  }

  // 拖动落点：网格画在卡片左侧，列表画在行顶
  @ViewBuilder private var insertionLine: some View {
    if draggedID != nil && dropTargetID == connection.id {
      if layout == .grid {
        Capsule().fill(KayoiTheme.primaryText.opacity(0.3)).frame(width: 2).padding(.vertical, Space.sm)
          .offset(x: -Space.xs - 1) // grid: ok 插入线落在两张卡片之间
      } else {
        Capsule().fill(KayoiTheme.primaryText.opacity(0.3)).frame(height: 2).padding(.horizontal, Space.sm)
          .offset(y: -1) // grid: ok 插入线落在两行之间
      }
    }
  }

  private var isIssue: Bool {
    if case .failed = state { return true }
    return state == .needsLogin
  }

  // 出错和登录过期的卡片带一点红或橙
  private var fill: Color {
    if case .failed = state { return hovering ? KayoiTheme.errorHover : KayoiTheme.errorBackground }
    if state == .needsLogin { return hovering ? KayoiTheme.warningHover : KayoiTheme.warningBackground }
    if selected { return KayoiTheme.selection }
    return hovering ? KayoiTheme.hover : KayoiTheme.surface
  }

  private var listFill: Color? {
    if case .failed = state { return hovering ? KayoiTheme.errorHover : KayoiTheme.errorBackground }
    if state == .needsLogin { return hovering ? KayoiTheme.warningHover : KayoiTheme.warningBackground }
    if selected { return KayoiTheme.selection }
    return hovering ? KayoiTheme.hover : nil
  }

  private var captionColor: Color {
    if case .failed = state { return KayoiTheme.error }
    return state == .needsLogin ? KayoiTheme.warning : KayoiTheme.tertiaryText
  }

  private var isReadOnly: Bool { ProviderAccess.isReadOnly(capabilities) }

  private var badge: PanelStatusIcon.Badge {
    switch state {
    case .connecting, .ejecting: .spinner
    case .awaitingAuthorization: .pulse(KayoiTheme.statusAmber)
    case .mounted: isReadOnly ? .lock : .dot(KayoiTheme.statusGreen)
    case .tested: isReadOnly ? .lock : .dot(KayoiTheme.statusBlue)
    case .unavailable: .dimmed
    case .needsLogin: .dot(KayoiTheme.statusAmber)
    case .failed: .dot(KayoiTheme.statusRed)
    case .disconnected: .none
    }
  }

  private var fullStatus: String { errorDetail.map { LF("无法连接：%@", $0) } ?? PanelCopy.subtitle(state, kind: connection.kind) }

  private var statusLine: String { isReadOnly ? L("只读") + " · " + fullStatus : fullStatus }
  private var hoverText: String { connection.name + "\n" + statusLine }

  // 点按或右键弹出的操作菜单：顶部是名称和状态
  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    // 顶部名称和状态用自绘视图，避免被系统画成灰色的禁用项
    let header = NSMenuItem()
    let headerView = NSHostingView(rootView: PanelMenuHeader(name: connection.name, status: statusLine, isIssue: isIssue))
    headerView.frame.size = headerView.fittingSize
    header.view = headerView
    menu.addItem(header)
    menu.addItem(.separator())
    for (index, group) in menuGroups.enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      for entry in group {
        menu.addItem(PanelMenuItem(entry.title, symbol: entry.symbol, destructive: entry.destructive, action: entry.action))
      }
    }
    return menu
  }

  struct MenuEntry {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
  }

  // 菜单分组，组间画分隔线；旁白的操作列表也用这份
  private var menuGroups: [[MenuEntry]] {
    var manage: [MenuEntry] = []
    if connection.kind.isCloud && state != .needsLogin { manage.append(MenuEntry(title: L("重新登录…"), symbol: "key", action: onReauthenticate)) }
    manage.append(MenuEntry(title: L("编辑…"), symbol: "pencil", action: onEdit))
    if canMoveUp { manage.append(MenuEntry(title: L("上移"), symbol: "arrow.up", action: { onMove(-1) })) }
    if canMoveDown { manage.append(MenuEntry(title: L("下移"), symbol: "arrow.down", action: { onMove(1) })) }
    let primary = primaryActions.map { MenuEntry(title: $0.0, symbol: $0.1, action: $0.2) }
    return [primary, manage, [MenuEntry(title: L("删除…"), symbol: "trash", destructive: true, action: onDelete)]]
      .filter { !$0.isEmpty }
  }

  // 每项：标题、SF Symbols 图标名、操作
  private var primaryActions: [(String, String, () -> Void)] {
    switch state {
    case .mounted(let mounted):
      [(L("在 Finder 中打开"), "folder", { if !isDemo { NSWorkspace.shared.open(mounted.url) } }),
       (L("推出"), "eject", onPrimary),
       (L("复制路径"), "doc.on.doc", { copy(mounted.url.path) })]
    case .connecting, .awaitingAuthorization: [(L("取消"), "xmark.circle", onPrimary)]
    case .ejecting, .unavailable: []
    case .needsLogin: [(L("重新登录…"), "key", onReauthenticate)]
    case .failed: [(L("重试"), "arrow.clockwise", onPrimary), (L("复制错误信息"), "doc.on.doc", { copy(fullStatus) })]
    case .tested, .disconnected:
      [(PanelCopy.buttonTitle(state, kind: connection.kind), connection.kind.usesSystemMount && state == .disconnected ? "externaldrive.badge.plus" : "checkmark.circle", onPrimary)]
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

struct PanelMenuHeader: View {
  let name: String
  let status: String
  let isIssue: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 2) { // grid: ok 名称与状态贴近
      Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KayoiTheme.primaryText).lineLimit(1)
      Text(status).font(.system(size: 11.5)).foregroundStyle(isIssue ? KayoiTheme.error : KayoiTheme.secondaryText)
        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 220, alignment: .leading)
    .padding(.horizontal, 14).padding(.top, Space.xs).padding(.bottom, Space.sm) // grid: ok 与菜单项文字对齐
  }
}

// 菜单项直接带闭包
final class PanelMenuItem: NSMenuItem {
  private let handler: () -> Void
  init(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) {
    handler = action
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    // macOS 27 默认隐藏菜单图标，这里要求显示
    if #available(macOS 27.0, *) { preferredImageVisibility = .visible }
    if destructive {
      attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
      // 删除类操作的图标也用红色
      image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
    }
  }
  required init(coder: NSCoder) { fatalError("不从 nib 创建") }
  @objc private func run() { handler() }
}

// 类型图标加右下角状态角标
struct PanelStatusIcon: View {
  enum Badge {
    case none, spinner, dot(Color), pulse(Color), lock, dimmed
  }
  let kind: ConnectionKind
  var color: String? = nil
  let size: CGFloat
  let badge: Badge
  // 角标外圈用所在卡片的底色，把角标和图标隔开
  let ring: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulsing = false

  var body: some View {
    TypeIcon(kind: kind, color: color, size: size)
      .opacity(isDimmed ? 0.45 : 1)
      .overlay(alignment: .bottomTrailing) {
        badgeView.offset(x: 2, y: 2) // grid: ok 角标压在图标右下角
      }
  }

  private var isDimmed: Bool { if case .dimmed = badge { return true }; return false }
  private var badgeSize: CGFloat { max(7, (size * 0.22).rounded()) }

  @ViewBuilder private var badgeView: some View {
    switch badge {
    case .none: EmptyView()
    case .dimmed:
      Circle().fill(KayoiTheme.statusGrey).frame(width: badgeSize, height: badgeSize)
        .padding(1.5).background(ring, in: Circle()) // grid: ok 角标外圈 1.5pt
    case .dot(let color):
      Circle().fill(color).frame(width: badgeSize, height: badgeSize)
        .padding(1.5).background(ring, in: Circle()) // grid: ok 角标外圈 1.5pt
    case .pulse(let color):
      Circle().fill(color).frame(width: badgeSize, height: badgeSize)
        .opacity(pulsing ? 0.35 : 1)
        .padding(1.5).background(ring, in: Circle()) // grid: ok 角标外圈 1.5pt
        .onAppear {
          guard !reduceMotion else { return }
          withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulsing = true }
        }
    case .lock:
      Image(systemName: "lock.fill").font(.system(size: badgeSize * 0.55, weight: .bold)).foregroundStyle(.white)
        .frame(width: badgeSize, height: badgeSize).background(KayoiTheme.statusGrey, in: Circle())
        .padding(1.5).background(ring, in: Circle()) // grid: ok 角标外圈 1.5pt
    case .spinner:
      ProgressView().nativeProgressAppearance().controlSize(.mini).scaleEffect(0.7)
        .frame(width: badgeSize + 2, height: badgeSize + 2)
        .padding(1).background(ring, in: Circle()) // grid: ok 转圈外圈 1pt
    }
  }
}
