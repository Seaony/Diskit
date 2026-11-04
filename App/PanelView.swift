import ADB
import AppKit
import CameraUSB
import Core
import RicohGR
import SwiftUI

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
  @State private var deleteTarget: Connection?
  @State private var actionError: PanelError?
  @State private var selectedConnectionID: UUID?
  @State private var scrollHeight: CGFloat = 240
  @FocusState private var keyboardFocus: Bool

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

  private var attentionCount: Int {
    model.connections.states.values.filter {
      if case .failed = $0 { return true }
      return $0 == .needsLogin
    }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      header.gridProbe("header", area: "panel", edge: nil)
      Divider()
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
              ForEach(Array(discoveredItems.enumerated()), id: \.element.id) { index, item in
                discoveryRow(item)
                  .modifier(PanelArrival(index: index))
              }
            }
            if model.connections.connections.isEmpty {
              emptyState
            } else {
              sectionTitle(L("已保存的位置"))
              ForEach(Array(model.connections.connections.enumerated()), id: \.element.id) {
                index, connection in
                SavedConnectionRow(
                  connection: connection,
                  state: model.connections.states[connection.id] ?? .disconnected,
                  errorDetail: model.connections.detailedErrors[connection.id],
                  capabilities: model.providerCapabilities(for: connection),
                  isDemo: model.options.isDemo,
                  dragSource: dragSource,
                  dropDisplacement: displacement(for: index),
                  dropDelay: displacementDelay(for: index),
                  selected: selection.id == connection.id,
                  rowFocus: $focusedConnectionID,
                  canMoveUp: index > 0,
                  canMoveDown: index + 1 < model.connections.connections.count,
                  onSelect: { selectedConnectionID = connection.id },
                  onPrimary: { primaryAction(connection) },
                  onEdit: { edit(connection) },
                  onReauthenticate: { edit(connection, reauthenticate: true) },
                  onMove: { offset in move(connection, offset: offset) },
                  onDelete: { deleteTarget = connection },
                  onDrop: { draggedID in move(draggedID, before: connection.id) }
                ).id(connection.id)
                  .gridProbe("row-" + connection.id.uuidString, area: "panel-list")
              }
            }
            if !showsEmptyState {
              addButton
                .overlay(alignment: .top) {
                  if draggedID != nil && endDropTargeted { Rectangle().fill(KayoiTheme.primaryText.opacity(0.15)).frame(height: 1) }
                }
                .onDrop(of: [.text], delegate: PanelDropDelegate(source: $draggedID, target: $dropTargetID, destination: nil, onTargeted: { endDropTargeted = $0 }, move: move))
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
      Divider()
      footer.gridProbe("footer", area: "panel", edge: nil)
    }
    .frame(width: 380)
    .gridArea("panel")
    .gridDiagnostics("panel")
    .demoAppearanceEvidence("panel")
    .background(KayoiTheme.background)
    .buttonStyle(FlatButtonStyle())
    .onDisappear { panelVisible = false }
    .onPreferenceChange(ScrollContentHeightKey.self) { scrollHeight = $0 }
    .background(PanelVisibilityObserver(visible: $panelVisible))
    .background(PanelKeyboardAnchor(handle: handleInitialKey))
    .onAppear {
      model.start()
      selectedConnectionID = model.connections.connections.first?.id
      keyboardFocus = true
    }
    .onChange(of: model.connections.connections.map(\.id)) { _, ids in
      if let selectedConnectionID, ids.contains(selectedConnectionID) { return }
      self.selectedConnectionID = ids.first
    }
    .onKeyPress(.upArrow) {
      moveSelection(-1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveSelection(1)
      return .handled
    }
    .onKeyPress(.return) {
      guard let connection = selectedConnection else { return .ignored }
      primaryAction(connection)
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
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(verbatim: "Kayoi").font(.title3.bold())
        if !model.connections.connections.isEmpty {
          Text(
            LF("%d 个位置", model.connections.connections.count)
          ).font(.caption).foregroundStyle(KayoiTheme.secondaryText)
        }
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
      Text(LF("Kayoi %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
        .monospacedDigit().font(.caption).foregroundStyle(KayoiTheme.secondaryText)
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

  private var addButton: some View {
    Button {
      edit(nil)
    } label: {
      Label(L("添加位置"), systemImage: "plus")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 40)
    }
    .buttonStyle(.plain)
    .keyboardShortcut("n", modifiers: .command)
    .accessibilityHint(L("添加手机、电脑、相机或网盘位置"))
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

  private func discoveryRow(_ item: DiscoveredItem) -> some View {
    HStack(spacing: Space.md) {
      TypeIcon(kind: item.kind, color: "gray", size: 28)
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(item.title).font(.body.weight(.medium)).lineLimit(1).help(item.title)
        Text(item.subtitle).font(.caption).foregroundStyle(KayoiTheme.secondaryText).lineLimit(1)
          .help(item.subtitle)
      }
      Spacer(minLength: 8)
      Button(L("添加")) {
        guard let connection = item.connection else { return }
        edit(connection)
        model.pairingSelection = item.pairingSelection
      }
      .fixedSize().disabled(item.connection == nil)
      .accessibilityLabel(LF("添加“%@”", item.title))
    }
    .padding(.horizontal, Space.sm).padding(.vertical, Space.xs).frame(minHeight: 52)
    .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        .strokeBorder(KayoiTheme.border, style: StrokeStyle(dash: [4, 3]))
    }
  }

  private var selectedConnection: Connection? {
    guard let id = selection.id else { return nil }
    return model.connections.connections.first { $0.id == id }
  }

  private func handleInitialKey(_ code: UInt16) -> Bool {
    switch code {
    case 126: moveSelection(-1)
    case 125: moveSelection(1)
    case 36, 76:
      guard let selectedConnection else { return false }
      primaryAction(selectedConnection)
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
      selectedConnectionID.flatMap { id in
        connections.firstIndex { $0.id == id }
      } ?? 0
    let next = min(max(current + offset, 0), connections.count - 1)
    selectedConnectionID = connections[next].id
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

  private func move(_ source: UUID, before target: UUID) {
    do { try model.connections.reorder(source, before: target) } catch {
      actionError = PanelError(title: L("调整位置顺序失败"), message: HumanError.detail(error))
    }
  }

  private func move(_ connection: Connection, offset: Int) {
    do {
      try model.connections.move(connection.id, offset: offset)
      selectedConnectionID = connection.id
    } catch {
      actionError = PanelError(title: L("调整位置顺序失败"), message: HumanError.detail(error))
    }
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
