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
  @State private var deleteTarget: Connection?
  @State private var actionError: PanelError?
  @State private var selectedConnectionID: UUID?
  @State private var scrollHeight: CGFloat = 240
  @FocusState private var keyboardFocus: Bool

  private var mergedWirelessDevices: [MergedWirelessDevice] {
    let grouped = Dictionary(grouping: model.wirelessDiscovery.devices) { device in
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

    for camera in model.ricohDiscovery.devices
    where !model.connections.connections.contains(where: {
      $0.kind == .ricohGR && $0.params["serial"] == camera.serial
    }) {
      items.append(
        DiscoveredItem(
          id: "camera:" + camera.id, kind: .ricohGR, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .ricohGR, name: camera.name, params: ["serial": camera.serial]),
          pairingSelection: nil))
    }

    for camera in model.cameraUSBDiscovery.devices
    where !model.connections.connections.contains(where: {
      $0.kind == .cameraUSB && $0.params["serial"] == camera.serial
    }) {
      items.append(
        DiscoveredItem(
          id: "camera-usb:" + camera.id, kind: .cameraUSB, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .cameraUSB, name: camera.name, params: ["serial": camera.serial]),
          pairingSelection: nil))
    }

    for device in model.usbDiscovery.devices
    where !model.connections.connections.contains(where: {
      $0.kind == .androidUSB && $0.params["serial"] == device.serial
    }) {
      items.append(
        DiscoveredItem(
          id: "usb:" + device.serial, kind: .androidUSB, title: device.name,
          subtitle: device.serial,
          connection: Connection(
            kind: .androidUSB, name: device.name, params: ["serial": device.serial]),
          pairingSelection: nil))
    }

    for device in mergedWirelessDevices where !isSaved(device) {
      let connect = device.connect
      let pairing = device.pairing
      let title =
        WirelessSelection.serial(fromGUID: device.serviceName).map {
          String.localizedStringWithFormat(L("安卓手机 · %@"), $0)
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
          id: "wifi:" + device.key, kind: .androidWiFi, title: title, subtitle: modes,
          connection: connection, pairingSelection: pairing?.id))
    }

    for device in model.discovery.devices
    where !model.connections.connections.contains(where: { $0.params["host"] == device.host }) {
      items.append(
        DiscoveredItem(
          id: "smb:" + device.id, kind: .smb, title: device.name,
          subtitle: device.host ?? L("正在查找地址"),
          connection: device.host.map {
            Connection(kind: .smb, name: device.name, params: ["host": $0])
          }, pairingSelection: nil))
    }

    return items.sorted { lhs, rhs in
      if lhs.kind == rhs.kind {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return lhs.kind.sortOrder < rhs.kind.sortOrder
    }
  }

  private var attentionCount: Int {
    model.connections.states.values.filter {
      if case .failed = $0 { return true }
      return $0 == .needsLogin
    }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            if let error = model.connections.loadError {
              errorBanner(error, title: L("无法读取位置列表"))
            }
            if let error = model.discovery.error ?? model.wirelessDiscovery.error {
              discoveryBanner(error)
            }
            if !discoveredItems.isEmpty {
              sectionTitle(L("已发现"))
              ForEach(discoveredItems) { item in
                discoveryRow(item)
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
                  selected: selectedConnectionID == connection.id,
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
              }
            }
            addButton
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: ScrollContentHeightKey.self, value: geometry.size.height)
            }
          }
        }
        .frame(height: min(max(scrollHeight, 120), 448))
        .onChange(of: selectedConnectionID) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
      }
      Divider()
      footer
    }
    .frame(width: 380)
    .background(KayoiTheme.background)
    .buttonStyle(FlatButtonStyle())
    .onPreferenceChange(ScrollContentHeightKey.self) { scrollHeight = $0 }
    .focusable()
    .focused($keyboardFocus)
    .focusEffectDisabled()
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
    .task {
      while !Task.isCancelled {
        model.connections.refreshMounts()
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
      }
    }
    .alert(item: $actionError) { error in
      Alert(
        title: Text(error.title),
        message: Text(error.message),
        primaryButton: .default(Text("好")),
        secondaryButton: .default(Text("复制详细信息")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(error.message, forType: .string)
        })
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } })
    ) {
      Button(L("删除位置"), role: .destructive) {
        removeSelectedConnection()
      }
    } message: {
      Text(deleteExplanation)
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Kayoi").font(.title2.bold())
        if !model.connections.connections.isEmpty {
          Text(
            String.localizedStringWithFormat(
              L("%d 个位置"), model.connections.connections.count)
          ).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if attentionCount > 0 {
        Label(
          String.localizedStringWithFormat(L("%d 个需要处理"), attentionCount),
          systemImage: "exclamationmark.circle.fill"
        )
        .font(.caption.weight(.medium)).foregroundStyle(.red)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.red.opacity(0.12), in: Capsule())
      } else if model.connections.mountedCount > 0 {
        Label(
          String.localizedStringWithFormat(
            L("%d 个已挂载"), model.connections.mountedCount),
          systemImage: "checkmark.circle.fill"
        )
        .font(.caption.weight(.medium)).foregroundStyle(KayoiTheme.accent)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(KayoiTheme.selection, in: Capsule())
      }
    }.padding(.horizontal, 16).padding(.vertical, 14)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("Kayoi \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button {
        openWindow(id: "help")
        NSApplication.shared.activate(ignoringOtherApps: true)
      } label: {
        Image(systemName: "questionmark.circle")
      }
      .keyboardShortcut("?", modifiers: .command)
      .help(L("帮助")).accessibilityLabel(L("打开 Kayoi 帮助"))
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)
      .help(L("设置")).accessibilityLabel(L("打开设置"))
      Button(action: requestQuit) {
        Image(systemName: "power")
      }
      .keyboardShortcut("q", modifiers: .command)
      .help(L("退出")).accessibilityLabel(L("退出 Kayoi"))
    }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 11)
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 18)
          .fill(KayoiTheme.selection)
          .frame(width: 72, height: 72)
        Image(systemName: "externaldrive.badge.plus")
          .font(.system(size: 32, weight: .regular))
          .foregroundStyle(KayoiTheme.accent)
      }
      VStack(spacing: 5) {
        Text("还没有保存的位置").font(.headline)
        Text("插上手机、打开无线调试，或添加网络位置。设备会自动出现在这里。")
          .font(.caption).foregroundStyle(.secondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      Button(L("添加位置")) { edit(nil) }
        .buttonStyle(FlatButtonStyle(prominent: true))
    }
    .frame(maxWidth: .infinity).padding(.vertical, 30)
  }

  private var addButton: some View {
    Button {
      edit(nil)
    } label: {
      Label(L("添加位置"), systemImage: "plus")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(FlatButtonStyle())
    .keyboardShortcut("n", modifiers: .command)
    .accessibilityHint(L("添加手机、电脑、相机或网盘位置"))
  }

  private func discoveryBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "wifi.exclamationmark")
        .foregroundStyle(.orange).font(.system(size: 18))
      VStack(alignment: .leading, spacing: 6) {
        Text(L("部分设备暂时无法发现")).font(.subheadline.weight(.semibold))
        Text(message)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if message.contains(L("本地网络权限")) {
          Button(L("打开本地网络设置")) {
            NSWorkspace.shared.open(
              URL(
                string:
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
              )!)
          }.controlSize(.small)
        } else {
          Button(L("添加位置")) { edit(nil) }.controlSize(.small)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35))
    }
  }

  private func errorBanner(_ error: String, title: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Spacer()
    }.padding(12).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      .padding(.top, 2)
  }

  private func discoveryRow(_ item: DiscoveredItem) -> some View {
    HStack(spacing: 11) {
      KindIcon(kind: item.kind, color: item.kind.accentColor)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.body.weight(.medium)).lineLimit(1).help(item.title)
        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          .help(item.subtitle)
      }
      Spacer(minLength: 8)
      Button(L("添加")) {
        guard let connection = item.connection else { return }
        edit(connection)
        model.pairingSelection = item.pairingSelection
      }
      .fixedSize().disabled(item.connection == nil)
      .accessibilityLabel(String.localizedStringWithFormat(L("添加“%@”"), item.title))
    }
    .frame(minHeight: 52).padding(.horizontal, 11).padding(.vertical, 7)
    .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(KayoiTheme.border, style: StrokeStyle(dash: [4, 3]))
    }
  }

  private var selectedConnection: Connection? {
    guard let selectedConnectionID else { return nil }
    return model.connections.connections.first { $0.id == selectedConnectionID }
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
    if model.connections.states[connection.id] == .needsLogin {
      edit(connection, reauthenticate: true)
    } else {
      Task { await model.connections.toggle(connection) }
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
    return String.localizedStringWithFormat(L("删除“%@”？"), deleteTarget.name)
  }

  private var deleteExplanation: String {
    guard let deleteTarget else { return "" }
    if deleteTarget.kind == .smb {
      return L("已挂载的共享会先推出。密码会从钥匙串删除，本机文件不会受影响。")
    }
    if deleteTarget.kind.isCloud {
      return L("登录信息会从钥匙串删除，本机文件不会受影响。")
    }
    return L("Kayoi 保存的位置、密钥和本地缓存会删除，设备或网盘上的文件不会受影响。")
  }

  private func removeSelectedConnection() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        try await model.connections.remove(target)
      } catch {
        actionError = PanelError(
          title: String.localizedStringWithFormat(L("删除“%@”失败"), target.name),
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
    openWindow(id: "settings")
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

private struct SavedConnectionRow: View {
  let connection: Connection
  let state: ConnectionState
  let errorDetail: String?
  let selected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onSelect: () -> Void
  let onPrimary: () -> Void
  let onEdit: () -> Void
  let onReauthenticate: () -> Void
  let onMove: (Int) -> Void
  let onDelete: () -> Void
  let onDrop: (UUID) -> Void

  @State private var hoveringForDrop = false
  @State private var dragging = false

  var body: some View {
    HStack(spacing: 11) {
      ZStack {
        KindIcon(kind: connection.kind, color: connection.tint)
        if state == .connecting {
          Color.black.opacity(0.32).clipShape(RoundedRectangle(cornerRadius: 7))
          ProgressView().controlSize(.mini).tint(.white)
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(connection.name).font(.body.weight(.medium)).lineLimit(1).help(connection.name)
        HStack(spacing: 4) {
          if case .tested = state {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(KayoiTheme.accent)
          } else if case .failed = state {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
          }
          Text(PanelCopy.subtitle(state)).lineLimit(1)
            .help(fullSubtitle)
        }.font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      Button(action: onPrimary) {
        if state == .connecting {
          ProgressView().controlSize(.mini).frame(width: 62)
        } else {
          Label(PanelCopy.buttonTitle(state, kind: connection.kind), systemImage: buttonSymbol)
            .labelStyle(.titleAndIcon)
        }
      }
      .fixedSize()
      .buttonStyle(FlatButtonStyle(prominent: isProminent))
      .disabled(state == .connecting)
      .accessibilityLabel(
        String.localizedStringWithFormat(
          L("%@“%@”"), PanelCopy.buttonTitle(state, kind: connection.kind), connection.name))
    }
    .frame(minHeight: 52).padding(.horizontal, 11).padding(.vertical, 7)
    .background(
      selected ? KayoiTheme.selection : KayoiTheme.surface,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(selected ? KayoiTheme.accent : KayoiTheme.border, lineWidth: selected ? 2 : 1)
    }
    .overlay(alignment: .top) {
      if hoveringForDrop {
        Capsule().fill(KayoiTheme.accent).frame(height: 3).padding(.horizontal, 9).offset(y: -2)
      }
    }
    .opacity(dragging ? 0.48 : 1)
    .scaleEffect(dragging ? 0.98 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture(perform: onSelect)
    .onDrag {
      dragging = true
      return NSItemProvider(object: connection.id.uuidString as NSString)
    } preview: {
      Label(connection.name, systemImage: connection.kind.symbol)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(KayoiTheme.background, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
          Task {
            try? await Task.sleep(for: .seconds(1))
            dragging = false
          }
        }
    }
    .dropDestination(for: String.self) { values, _ in
      dragging = false
      guard let value = values.first, let id = UUID(uuidString: value) else { return false }
      onDrop(id)
      return true
    } isTargeted: {
      hoveringForDrop = $0
    }
    .contextMenu {
      if case .mounted(let mounted) = state {
        Button(L("在 Finder 中打开")) { NSWorkspace.shared.open(mounted.url) }
        Button(L("复制路径")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(mounted.url.path, forType: .string)
        }
        Button(L("推出")) { onPrimary() }
      }
      if case .failed = state {
        Button(L("复制错误信息")) { copy(errorDetail ?? PanelCopy.subtitle(state)) }
      }
      Button(L("编辑")) { onEdit() }
      if connection.kind.isCloud {
        Button(L("重新登录")) { onReauthenticate() }
      }
      Divider()
      Button(L("上移")) { onMove(-1) }.disabled(!canMoveUp)
      Button(L("下移")) { onMove(1) }.disabled(!canMoveDown)
      Divider()
      Button(L("删除位置"), role: .destructive) { onDelete() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var fullSubtitle: String {
    switch state {
    case .failed: errorDetail ?? PanelCopy.subtitle(state)
    default: PanelCopy.subtitle(state)
    }
  }

  private var isProminent: Bool {
    switch state {
    case .needsLogin, .failed, .disconnected: true
    default: false
    }
  }

  private var buttonSymbol: String {
    switch state {
    case .connecting: "hourglass"
    case .mounted: "eject"
    case .tested: "checkmark"
    default: connection.kind.usesSystemMount ? "arrow.up.right" : "bolt.horizontal"
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

private struct KindIcon: View {
  let kind: ConnectionKind
  let color: Color
  var body: some View {
    Image(systemName: kind.symbol)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 28, height: 28)
      .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
  }
}

private enum PanelCopy {
  static func subtitle(_ state: ConnectionState) -> String {
    switch state {
    case .needsLogin: L("需要重新登录")
    case .disconnected: L("未连接")
    case .connecting: L("正在连接…")
    case .failed(let error): error
    case .tested(let space):
      String.localizedStringWithFormat(
        L("测试成功 · 可用 %@"),
        ByteCountFormatter.string(fromByteCount: space.available, countStyle: .file))
    case .mounted(let mount):
      String.localizedStringWithFormat(
        L("已挂载 · 可用 %@"),
        ByteCountFormatter.string(fromByteCount: mount.availableBytes, countStyle: .file))
    }
  }

  static func buttonTitle(_ state: ConnectionState, kind: ConnectionKind) -> String {
    switch state {
    case .needsLogin: L("重新登录")
    case .tested: kind.usesSystemMount ? L("挂载") : L("再次测试")
    case .mounted: L("推出")
    case .failed: L("重试")
    case .connecting: L("连接中…")
    case .disconnected: kind.usesSystemMount ? L("挂载") : L("测试连接")
    }
  }
}

extension Connection {
  var tint: Color {
    switch color {
    case "green": Color(red: 0.16, green: 0.66, blue: 0.45)
    case "orange": Color(red: 0.93, green: 0.52, blue: 0.18)
    case "red": Color(red: 0.86, green: 0.26, blue: 0.28)
    case "purple": Color(red: 0.56, green: 0.36, blue: 0.78)
    case "pink": Color(red: 0.88, green: 0.35, blue: 0.59)
    case "teal": Color(red: 0.12, green: 0.59, blue: 0.62)
    case "indigo": Color(red: 0.35, green: 0.38, blue: 0.78)
    case "gray": Color(red: 0.44, green: 0.48, blue: 0.50)
    default: Color(red: 0.18, green: 0.46, blue: 0.83)
    }
  }
}
