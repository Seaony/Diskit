import ADB
import AppKit
import CameraUSB
import Core
import RicohGR
import SwiftUI
import UniformTypeIdentifiers

private struct PanelError: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private struct DiscoveredItem: Identifiable {
  let id: String
  let kind: ConnectionKind
  let title: String
  let subtitle: String
  let connection: Connection?
  let pairingSelection: String?
}

private struct MergedWirelessDevice {
  let key: String
  let pairing: WirelessDevice?
  let connect: WirelessDevice?
  var serviceName: String { connect?.name ?? pairing?.name ?? key }
}

private struct ScrollContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct PanelView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var showSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var panelVisible = false
  @State private var draggedID: UUID?
  @State private var dragSource = PanelDraggingSource()
  @State private var dropTargetID: UUID?
  @State private var endDropTargeted = false
  @State private var addHovering = false
  @State private var deleteTarget: Connection?
  @State private var actionError: PanelError?
  @State private var selection = PanelSelection()
  @State private var scrollHeight: CGFloat = 240
  @FocusState private var focusedConnectionID: UUID?

  private var mergedWirelessDevices: [MergedWirelessDevice] {
    let grouped = Dictionary(grouping: model.wirelessDevices) { device in
      WirelessSelection.serial(fromGUID: device.name) ?? device.name
    }
    return grouped.map { key, devices in
      MergedWirelessDevice(
        key: key,
        pairing: devices.first { $0.type == .pairing },
        connect: devices.first { $0.type == .connect })
    }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }

  private var discoveredItems: [DiscoveredItem] {
    var items: [DiscoveredItem] = []

    for camera in model.ricohDevices
    where !PanelDiscoveryIdentity.isSavedDevice(model.connections.connections, kinds: [.ricohGR, .cameraUSB], id: camera.id, serial: camera.serial, serialIsUnique: model.ricohDevices.filter { $0.serial == camera.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "camera:" + camera.id, kind: .ricohGR, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .ricohGR, name: camera.name, params: ["deviceID": camera.id, "serial": camera.serial]),
          pairingSelection: nil))
    }

    for camera in model.cameraUSBDevices
    where !model.ricohDevices.contains(where: { PanelDiscoveryIdentity.sameCamera(id: camera.id, serial: camera.serial, otherID: $0.id, otherSerial: $0.serial) }) && !PanelDiscoveryIdentity.isSavedDevice(model.connections.connections, kinds: [.ricohGR, .cameraUSB], id: camera.id, serial: camera.serial, serialIsUnique: model.cameraUSBDevices.filter { $0.serial == camera.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "camera-usb:" + camera.id, kind: .cameraUSB, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .cameraUSB, name: camera.name, params: ["deviceID": camera.id, "serial": camera.serial]),
          pairingSelection: nil))
    }

    for device in model.usbDevices
    where !PanelDiscoveryIdentity.isSavedDevice(model.connections.connections, kinds: [.androidUSB], id: device.id, serial: device.serial, serialIsUnique: model.usbDevices.filter { $0.serial == device.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "usb:" + device.id, kind: .androidUSB, title: device.name,
          subtitle: "USB · " + device.name,
          connection: Connection(
            kind: .androidUSB, name: device.name, params: device.connectionParameters(in: model.usbDevices)),
          pairingSelection: nil))
    }

    for device in mergedWirelessDevices where !isSaved(device) {
      let connect = device.connect
      let pairing = device.pairing
      let title =
        WirelessSelection.serial(fromGUID: device.serviceName).map {
          LF("安卓手机 · %@", $0)
        }
        ?? device.serviceName
      let modes =
        [pairing == nil ? nil : L("可配对"), connect == nil ? nil : L("可连接")]
        .compactMap { $0 }.joined(separator: L(" · "))
      let connection = Connection(
        kind: .androidWiFi, name: title,
        params: connect.map { ["guid": $0.name] } ?? [:])
      items.append(
        DiscoveredItem(
          id: "wifi:" + device.key, kind: .androidWiFi, title: title, subtitle: L("Wi‑Fi 无线调试") + " · " + modes,
          connection: connection, pairingSelection: pairing?.id))
    }

    for device in model.smbDevices
    where !PanelDiscoveryIdentity.isSavedSMB(model.connections.connections, id: device.id, host: device.host) {
      items.append(
        DiscoveredItem(
          id: "smb:" + device.id, kind: .smb, title: device.name,
          subtitle: L("局域网") + " · " + (device.host ?? device.name),
          connection: Connection(kind: .smb, name: device.name, params: ["bonjourID": device.id].merging(device.host.map { ["host": $0] } ?? [:]) { _, new in new }), pairingSelection: nil))
    }

    return items.sorted { lhs, rhs in
      if lhs.kind == rhs.kind {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return lhs.kind.sortOrder < rhs.kind.sortOrder
    }
  }

  private var discoveryErrors: [(message: String, permissionDenied: Bool)] {
    if let error = model.options.demoDiscoveryError {
      return [(error.message, error.permissionDenied)]
    }
    return [
      model.discovery.error.map { ($0, model.discovery.issue == .permissionDenied) },
      model.wirelessDiscovery.error.map { ($0, model.wirelessDiscovery.issue == .permissionDenied) },
      model.usbDiscovery.issue.map { _ in (L("暂时无法发现 USB 手机，请重新插拔设备"), false) },
      model.ricohDiscovery.issue.map { _ in (L("暂时无法发现理光相机，请检查 USB 连接"), false) },
      model.cameraUSBDiscovery.issue.map { _ in (L("暂时无法发现相机，请检查 USB 连接"), false) }
    ].compactMap { $0 }
  }

  private var showsEmptyState: Bool {
    PanelCopy.showsEmptyState(savedCount: model.connections.connections.count, discoveredCount: discoveredItems.count)
  }

  private var attentionCount: Int {
    model.connections.states.values.filter {
      if case .failed = $0 { return true }
      return $0 == .needsLogin
    }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      if !model.connections.connections.isEmpty || statusTarget != nil {
        header.gridProbe("header", area: "panel", edge: nil)
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Space.md) {
            if let error = model.demoSetupError ?? model.connections.loadError {
              errorBanner(error, title: L("无法读取位置列表"))
            }
            ForEach(discoveryErrors, id: \.message) { error in
              discoveryBanner(error.message, permissionDenied: error.permissionDenied)
            }
            if !discoveredItems.isEmpty {
              sectionTitle(L("已发现"))
              LazyVGrid(columns: cardColumns, spacing: Space.md) {
                ForEach(Array(discoveredItems.enumerated()), id: \.element.id) { index, item in
                  discoveryCard(item)
                    .modifier(PanelArrival(index: index))
                }
              }
            }
            if showsEmptyState {
              emptyState
            } else if !model.connections.connections.isEmpty {
              sectionTitle(L("我的位置"))
              LazyVGrid(columns: cardColumns, spacing: Space.md) {
              ForEach(Array(model.connections.connections.enumerated()), id: \.element.id) {
                index, connection in
                SavedConnectionRow(
                  connection: connection,
                  state: model.connections.states[connection.id] ?? .disconnected,
                  errorDetail: model.connections.detailedErrors[connection.id],
                  capabilities: model.providerCapabilities(for: connection),
                  isDemo: model.options.isDemo,
                  dragSource: dragSource,
                  selected: selection.id == connection.id,
                  rowFocus: $focusedConnectionID,
                  canMoveUp: index > 0,
                  canMoveDown: index + 1 < model.connections.connections.count,
                  onSelect: { selection.select(connection.id, reveal: false); focusedConnectionID = connection.id },
                  onPrimary: { primaryAction(connection) },
                  onActivate: { activate(connection) },
                  onEdit: { edit(connection) },
                  onReauthenticate: { edit(connection, reauthenticate: true) },
                  onMove: { offset in move(connection, offset: offset) },
                  onDelete: { deleteTarget = connection },
                  draggedID: $draggedID,
                  dropTargetID: $dropTargetID,
                  onDrop: { draggedID in move(draggedID, before: connection.id) }
                ).id(connection.id)
                  .gridProbe("row-" + connection.id.uuidString, area: "panel-list")
              }
              addCard
              }
            }
            if !showsEmptyState && model.connections.connections.isEmpty {
              LazyVGrid(columns: cardColumns, spacing: Space.md) { addCard }
            }
          }
          .padding(.horizontal, Space.margin)
          .padding(.vertical, Space.md)
          .gridArea("panel-list", inset: Space.margin)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: ScrollContentHeightKey.self, value: geometry.size.height)
            }
          }
        }
        .frame(height: min(max(scrollHeight, 120), 432))
        .onChange(of: selection.scrollRequest) { _, request in
          guard let request else { return }
          if reduceMotion { proxy.scrollTo(request.connectionID, anchor: .center) }
          else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(request.connectionID, anchor: .center) } }
        }
      }
      footer.gridProbe("footer", area: "panel", edge: nil)
    }
    .frame(width: 380)
    .gridArea("panel")
    .gridDiagnostics("panel")
    .demoAppearanceEvidence("panel")
    .background(KayoiTheme.background)
    .buttonStyle(FlatButtonStyle())
    .onDisappear { panelVisible = false }
    .onChange(of: draggedID) { _, id in
      if id == nil { dropTargetID = nil; endDropTargeted = false }
    }
    .onPreferenceChange(ScrollContentHeightKey.self) { scrollHeight = $0 }
    .background(PanelVisibilityObserver(visible: $panelVisible))
    .background(PanelKeyboardAnchor(handle: handleInitialKey))
    .onAppear {
      model.start()
      selection.select(model.connections.connections.first?.id, reveal: false)
    }
    .onChange(of: focusedConnectionID) { _, id in
      if let id, id != selection.id { selection.select(id, reveal: false) }
    }
    .onChange(of: model.connections.connections.map(\.id)) { _, ids in
      if let id = selection.id, ids.contains(id) { return }
      selection.select(ids.first, reveal: false)
    }
    .onKeyPress(.upArrow) {
      moveSelection(-2)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveSelection(2)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      moveSelection(-1)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      moveSelection(1)
      return .handled
    }
    .onKeyPress(.return) {
      guard let connection = selectedConnection else { return .ignored }
      activate(connection)
      return .handled
    }
    .onKeyPress(.delete) {
      guard let selectedConnection else { return .ignored }; deleteTarget = selectedConnection; return .handled
    }
    .onKeyPress(.escape) {
      if draggedID != nil { draggedID = nil; return .handled }
      NSApplication.shared.keyWindow?.close()
      return .handled
    }
    .focusedSceneValue(\.panelCommands, PanelCommandActions(
      canEdit: selectedConnection != nil, canDelete: selectedConnection != nil,
      edit: { if let selectedConnection { edit(selectedConnection) } },
      delete: { if let selectedConnection { deleteTarget = selectedConnection } }))
    .task(id: panelVisible) {
      guard panelVisible, !model.options.isDemo else { return }
      while !Task.isCancelled {
        await model.connections.refreshMountSpace()
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
      }
    }
    .alert(actionError?.title ?? "", isPresented: Binding(
      get: { actionError != nil }, set: { if !$0 { actionError = nil } }
    ), presenting: actionError) { error in
      Button(L("好"), role: .cancel) { actionError = nil }
      Button(L("复制详细信息")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(error.message, forType: .string)
      }
    } message: { error in
      Text(error.message)
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } })
    ) {
      Button(L("删除"), role: .destructive) {
        removeSelectedConnection()
      }
      Button(L("取消"), role: .cancel) { deleteTarget = nil }
    } message: {
      Text(deleteExplanation)
    }
  }

  // 两列卡片
  private var cardColumns: [GridItem] {
    [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)]
  }

  private var statusTarget: (id: UUID, label: String, symbol: String, color: Color, background: Color)? {
    let connections = model.connections.connections
    if let connection = connections.first(where: {
      let state = model.connections.states[$0.id]
      if case .some(.failed) = state { return true }
      return state == .needsLogin
    }) {
      return (connection.id, LF("%d 个需要处理", attentionCount), "exclamationmark.circle.fill", KayoiTheme.error, KayoiTheme.errorBackground)
    }
    if let connection = connections.first(where: { model.connections.states[$0.id] == .connecting || model.connections.states[$0.id] == .awaitingAuthorization }) {
      return (connection.id, L("正在连接…"), "arrow.triangle.2.circlepath", KayoiTheme.secondaryText, KayoiTheme.hover)
    }
    if let connection = connections.first(where: { if case .some(.mounted) = model.connections.states[$0.id] { return true }; return false }) {
      return (connection.id, LF("%d 个已挂载", model.connections.mountedCount), "checkmark.circle.fill", KayoiTheme.accent, KayoiTheme.selection)
    }
    return nil
  }

  private var header: some View {
    HStack {
      if !model.connections.connections.isEmpty {
        Text(LF("%d 个位置", model.connections.connections.count))
          .font(.headline).foregroundStyle(KayoiTheme.primaryText)
      }
      Spacer()
      if let statusTarget {
        Button { selection.select(statusTarget.id, reveal: true) } label: {
          Label(statusTarget.label, systemImage: statusTarget.symbol)
            .font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(statusTarget.color)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .background(statusTarget.background, in: Capsule())
        }.buttonStyle(.plain)
      }
    }.padding(.horizontal, Space.margin).padding(.vertical, Space.md)
  }

  private var footer: some View {
    HStack(spacing: Space.md) {
      Spacer()
      Button {
        openWindow(id: "help")
        NSApplication.shared.activate(ignoringOtherApps: true)
      } label: {
        Image(systemName: "questionmark.circle")
      }
      .keyboardShortcut("?", modifiers: .command)
      .help(L("帮助 · ⌘?")).accessibilityLabel(L("打开 Kayoi 帮助"))
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)
      .help(L("设置 · ⌘,")).accessibilityLabel(L("打开设置"))
      Button(action: requestQuit) {
        Image(systemName: "power")
      }
      .keyboardShortcut("q", modifiers: .command)
      .help(L("退出 · ⌘Q")).accessibilityLabel(L("退出 Kayoi"))
    }.buttonStyle(FlatIconButtonStyle()).padding(.horizontal, Space.margin).padding(.vertical, Space.sm)
  }

  private var emptyState: some View {
    VStack(spacing: Space.lg) {
      EmptyLocationIcon(size: 64)
      VStack(spacing: Space.xs) {
        Text(L("还没有保存的位置")).font(.headline)
        Text(L("插上手机、打开无线调试，或添加网络共享和网盘"))
          .font(.caption).foregroundStyle(KayoiTheme.secondaryText)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      Button(L("添加位置")) { edit(nil) }
        .buttonStyle(FlatButtonStyle(prominent: true))
    }
    .frame(maxWidth: .infinity).padding(.vertical, Space.section)
  }

  private var addCard: some View {
    Button {
      edit(nil)
    } label: {
      VStack(spacing: Space.sm) {
        Image(systemName: "plus").font(.title3.weight(.medium)).foregroundStyle(KayoiTheme.accent)
        Text(L("添加位置")).font(.subheadline.weight(.medium)).foregroundStyle(KayoiTheme.secondaryText)
      }
      .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92)
      .background(addHovering ? KayoiTheme.hover : KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
      // 拖到这里放到最后
      .overlay(alignment: .leading) {
        if draggedID != nil && endDropTargeted {
          Capsule().fill(KayoiTheme.primaryText.opacity(0.3)).frame(width: 2).padding(.vertical, Space.sm)
            .offset(x: -Space.sm + 1) // grid: ok 插入线落在两张卡片之间
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { addHovering = $0 }
    .keyboardShortcut("n", modifiers: .command)
    .help(L("添加位置 · ⌘N"))
    .accessibilityHint(L("添加手机、电脑、相机或网盘位置"))
    .onDrop(of: [.text], delegate: PanelDropDelegate(source: $draggedID, target: $dropTargetID, destination: nil, onTargeted: { endDropTargeted = $0 }, move: move))
  }

  private func discoveryBanner(_ message: String, permissionDenied: Bool) -> some View {
    PanelDiscoveryBanner(message: message, permissionDenied: permissionDenied) {
      if permissionDenied {
        guard !model.options.isDemo else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
      } else { edit(nil) }
    }
  }

  private func errorBanner(_ error: String, title: String) -> some View {
    PanelFailureBanner(title: title, message: error)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.caption.weight(.medium)).foregroundStyle(KayoiTheme.secondaryText)
      .padding(.top, Space.xs)
  }

  // 发现的设备：整张卡片点一下就是添加
  private func discoveryCard(_ item: DiscoveredItem) -> some View {
    Button {
      guard let connection = item.connection else { return }
      edit(connection)
      model.pairingSelection = item.pairingSelection
    } label: {
      VStack(spacing: Space.sm) {
        TypeIcon(kind: item.kind, color: "gray", size: 36)
        Text(item.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(KayoiTheme.primaryText)
      }
      .padding(Space.md)
      .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92)
    }
    .buttonStyle(PanelCardButtonStyle())
    .disabled(item.connection == nil)
    .help(LF("添加“%@”", item.title))
    .accessibilityLabel(LF("添加“%@”", item.title))
  }

  private var selectedConnection: Connection? {
    guard let id = selection.id else { return nil }
    return model.connections.connections.first { $0.id == id }
  }

  private func handleInitialKey(_ code: UInt16) -> Bool {
    switch code {
    case 126: moveSelection(-2)
    case 125: moveSelection(2)
    case 123: moveSelection(-1)
    case 124: moveSelection(1)
    case 36, 76:
      guard let selectedConnection else { return false }
      activate(selectedConnection)
    case 51:
      guard let selectedConnection else { return false }
      deleteTarget = selectedConnection
    case 53:
      if draggedID != nil { draggedID = nil }
      else { NSApplication.shared.keyWindow?.close() }
    default: return false
    }
    return true
  }

  private func moveSelection(_ offset: Int) {
    let connections = model.connections.connections
    guard !connections.isEmpty else { return }
    let current =
      selection.id.flatMap { id in
        connections.firstIndex { $0.id == id }
      } ?? 0
    // 上下换行时没有目标行就停在原地，不横跳到隔壁格子
    if abs(offset) > 1 && !connections.indices.contains(current + offset) { return }
    let next = min(max(current + offset, 0), connections.count - 1)
    selection.select(connections[next].id, reveal: true)
    focusedConnectionID = connections[next].id
  }

  // 点卡片或回车：已挂载就在 Finder 打开，进行中或不可用时不动，其余执行主操作
  private func activate(_ connection: Connection) {
    switch model.connections.states[connection.id] ?? .disconnected {
    case .mounted(let mounted): if !model.options.isDemo { NSWorkspace.shared.open(mounted.url) }
    case .connecting, .awaitingAuthorization, .ejecting, .unavailable: break
    default: primaryAction(connection)
    }
  }

  private func primaryAction(_ connection: Connection) {
    let state = model.connections.states[connection.id] ?? .disconnected
    if state == .connecting || state == .awaitingAuthorization {
      model.operations.cancel(connectionID: connection.id)
      model.connections.cancelIdleOperation(connection)
    } else if state == .unavailable || state == .ejecting {
      return
    } else if state == .needsLogin {
      edit(connection, reauthenticate: true)
    } else {
      model.operations.start(connectionID: connection.id) { await model.connections.toggle(connection) }
    }
  }

  private func move(_ source: UUID, before target: UUID?) {
    let ids = model.connections.connections.map(\.id)
    guard let index = ids.firstIndex(of: source) else { return }
    let previousNext = ids.dropFirst(index + 1).first
    guard target != source, target != previousNext else { return }
    do {
      try model.connections.reorder(source, before: target)
      model.undoManager.registerUndo(withTarget: model.connections) { _ in
        MainActor.assumeIsolated { move(source, before: previousNext) }
      }
      model.undoManager.setActionName(L("调整位置顺序"))
    } catch {
      actionError = PanelError(title: L("调整位置顺序失败"), message: HumanError.detail(error))
    }
  }

  private func move(_ connection: Connection, offset: Int) {
    let ids = model.connections.connections.map(\.id)
    guard let index = ids.firstIndex(of: connection.id) else { return }
    let destination = min(max(index + offset, 0), ids.count - 1)
    let target = offset < 0 ? ids[destination] : ids.dropFirst(destination + 1).first
    move(connection.id, before: target)
    selection.select(connection.id, reveal: true)
  }

  private var deleteTitle: String {
    guard let deleteTarget else { return L("删除位置？") }
    return LF("删除“%@”？", deleteTarget.name)
  }

  private var deleteExplanation: String {
    guard let deleteTarget else { return "" }
    if deleteTarget.kind.usesSystemMount {
      return L("会先推出这个共享。保存的登录信息会删除，共享里的文件不受影响。")
    }
    if deleteTarget.kind.isCloud {
      return L("会删除 Kayoi 保存的登录信息，网盘里的文件不受影响。")
    }
    return L("会删除 Kayoi 保存的位置和登录信息，设备上的文件不受影响。")
  }

  private func removeSelectedConnection() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        try await model.connections.remove(target)
      } catch {
        actionError = PanelError(
          title: LF("删除“%@”失败", target.name),
          message: HumanError.detail(error))
      }
    }
  }

  private func edit(_ connection: Connection?, reauthenticate: Bool = false) {
    model.forceLogin = reauthenticate
    model.pairingSelection = nil
    model.editing = connection
    openWindow(id: "connection")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func openSettings() {
    showSettings()
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func requestQuit() {
    NSApplication.shared.terminate(nil)
  }

  private func isSaved(_ device: MergedWirelessDevice) -> Bool {
    model.connections.connections.contains { connection in
      guard connection.kind == .androidWiFi, let guid = connection.params["guid"] else {
        return false
      }
      if guid == device.serviceName { return true }
      let services = [device.pairing, device.connect].compactMap { $0 }
      return services.contains { WirelessSelection.matches(guid: guid, service: $0) }
        || WirelessSelection.serial(fromGUID: guid) == device.key
    }
  }
}

extension Connection {
  var tint: Color { KayoiTheme.locationColor(color) }
}

// 面板卡片：只用底色区分静止、悬停、按下
struct PanelCardButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    configuration.label
      .background(configuration.isPressed ? KayoiTheme.pressed : hovering ? KayoiTheme.hover : KayoiTheme.surface, in: shape)
      .overlay { if isFocused { shape.strokeBorder(KayoiTheme.focus, lineWidth: 2) } }
      .contentShape(shape)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .onHover { hovering = $0 }
  }
}
