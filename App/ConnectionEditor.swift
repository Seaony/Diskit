import ADB
import AliyunDrive
import CameraUSB
import ChinaWebDrive
import CloudDrive
import Core
import LanzouDrive
import PikPakDrive
import Quark
import RicohGR
import SwiftUI
import TianyiDrive

private struct KindGroup: Identifiable {
  let title: String
  let kinds: [ConnectionKind]
  var id: String { title }
}

private struct ColorChoice: Identifiable {
  let value: String
  let title: String
  let color: Color
  var id: String { value }
}

private struct WebDAVPreset: Identifiable {
  let value: String
  let title: String
  let address: String
  let secure: Bool
  var id: String { value }
}

struct ConnectionEditor: View {
  @Bindable var model: AppModel
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var draft = Connection()
  @State private var password = ""
  @State private var shares: [String] = []
  @State private var error: String?
  @State private var busy = false
  @State private var chosen = false
  @State private var pairingCode = ""
  @State private var pairingID = ""
  @State private var webAuthorization: WebAuthorization?
  @State private var saving: Task<Void, Never>?
  @State private var pairingTask: Task<Void, Never>?
  @State private var shareTask: Task<Void, Never>?
  @State private var showQuarkLogin = false
  @State private var quarkSession: QuarkSession?
  @State private var quarkContinuation: CheckedContinuation<QuarkAccount, Error>?
  @State private var selectedKind: ConnectionKind?
  @State private var search = ""
  @State private var stage: String?
  @State private var passwordVisible = false
  @State private var guestLogin = false
  @State private var touchedFields: Set<String> = []
  @State private var preparationExpanded = false
  @State private var webdavPreset = "custom"
  @State private var tianyiFamilySpaces: [TianyiFamilySpace] = []

  private let colors = [
    ColorChoice(value: "blue", title: L("蓝色"), color: .blue),
    ColorChoice(value: "green", title: L("绿色"), color: .green),
    ColorChoice(value: "orange", title: L("橙色"), color: .orange),
    ColorChoice(value: "red", title: L("红色"), color: .red),
    ColorChoice(value: "purple", title: L("紫色"), color: .purple),
    ColorChoice(value: "pink", title: L("粉色"), color: .pink),
    ColorChoice(value: "teal", title: L("青色"), color: .teal),
    ColorChoice(value: "gray", title: L("灰色"), color: .gray),
  ]
  private let webdavPresets = [
    WebDAVPreset(value: "custom", title: L("自定义"), address: "", secure: true),
    WebDAVPreset(
      value: "jianguoyun", title: L("坚果云"), address: "https://dav.jianguoyun.com/dav/",
      secure: true),
    WebDAVPreset(
      value: "nextcloud", title: L("Nextcloud"),
      address: "https://example.com/remote.php/dav/files/USERNAME/",
      secure: true),
    WebDAVPreset(
      value: "synology", title: L("群晖 WebDAV"), address: "http://host:5005/", secure: false),
  ]

  private var groups: [KindGroup] {
    let all = [
      KindGroup(title: L("设备"), kinds: [.androidUSB, .ricohGR, .cameraUSB]),
      KindGroup(title: L("局域网"), kinds: [.smb, .webdav, .webdavHTTPS, .nfs]),
      KindGroup(
        title: L("网盘"),
        kinds: [
          .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
          .dropbox,
        ]),
      KindGroup(
        title: L("实验性网盘"),
        kinds: [.ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou]),
      KindGroup(
        title: L("对象存储"),
        kinds: [
          .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2,
        ]),
    ]
    guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return all }
    return all.compactMap { group in
      let kinds = group.kinds.filter {
        $0.title.localizedCaseInsensitiveContains(search)
          || $0.connectionCaption.localizedCaseInsensitiveContains(search)
      }
      return kinds.isEmpty ? nil : KindGroup(title: group.title, kinds: kinds)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      editorHeader
      Divider()
      ScrollView {
        Group {
          if chosen {
            connectionForm
          } else {
            kindPicker
          }
        }
        .padding(24)
      }
      Divider()
      footer
    }
    .buttonStyle(FlatButtonStyle())
    .toggleStyle(.checkbox)
    .frame(width: 600, height: 660)
    .background(KayoiTheme.background)
    .task {
      draft = model.editing ?? Connection()
      chosen = model.editing != nil
      pairingID = model.pairingSelection ?? ""
      if let connection = model.editing,
        connection.kind == .smb || connection.kind == .webdav || connection.kind == .webdavHTTPS
          || connection.kind.usesStoredRemoteSecret
      {
        do {
          password = try model.connections.savedPassword(connection)
          guestLogin = connection.params["guest"] == "true"
        } catch {
          model.connections.reportOperationError(error)
          self.error = HumanError.detail(error, kind: draft.kind)
        }
      }
      autoSelectDevice()
    }
    .onDisappear(perform: cancelWork)
    .sheet(
      isPresented: $showQuarkLogin,
      onDismiss: { finishQuark(.failure(CancellationError())) }
    ) {
      if let session = quarkSession {
        QuarkLoginView(
          session: session,
          onSuccess: { finishQuark(.success($0)) },
          onCancel: { finishQuark(.failure(CancellationError())) }
        )
        .presentationBackground(KayoiTheme.background)
      }
    }
    .onChange(of: draft.params["host"]) { shares = [] }
    .onChange(of: draft.params["username"]) { shares = [] }
    .onChange(of: draft.params["serial"]) { _, _ in autoNameFromDevice() }
    .onChange(of: guestLogin) { _, guest in
      if !guest { touchedFields.insert("username") }
    }
    .onChange(of: pairingCode) { _, value in
      touchedFields.insert("pairingCode")
      let digits = String(value.filter(\.isNumber).prefix(6))
      if digits != value { pairingCode = digits }
      if digits.count == 6, draft.params["guid"] == nil {
        pairWirelessDevice()
      }
    }
    .onChange(of: model.usbDevices.map(\.serial)) { _, _ in autoSelectDevice() }
    .onChange(of: model.ricohDevices.map(\.serial)) { _, _ in autoSelectDevice() }
    .onChange(of: model.cameraUSBDevices.map(\.serial)) { _, _ in autoSelectDevice() }
  }

  private var editorHeader: some View {
    HStack(spacing: 14) {
      if chosen {
        Image(systemName: draft.kind.symbol)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(draft.tint)
          .frame(width: 48, height: 48)
          .background(draft.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(model.editing == nil ? L("添加位置") : L("编辑位置"))
          .font(.system(size: 23, weight: .semibold))
        Text(chosen ? draft.kind.title : L("选择要连接的位置类型"))
          .font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      if chosen {
        Text(L("连接设置")).font(.caption).foregroundStyle(.secondary)
      }
    }.padding(.horizontal, 24).padding(.vertical, 18)
  }

  private var kindPicker: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(L("搜索位置类型"), text: $search)
          .textFieldStyle(.plain)
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12).frame(height: 36)
      .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 9))
      .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(KayoiTheme.border) }

      ForEach(groups) { group in
        VStack(alignment: .leading, spacing: 10) {
          Text(group.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12
          ) {
            ForEach(group.kinds, id: \.self) { kind in
              Button {
                selectedKind = kind
              } label: {
                VStack(spacing: 10) {
                  Image(systemName: kind.symbol)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(kind.accentColor)
                    .frame(height: 34)
                  VStack(spacing: 4) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                      .multilineTextAlignment(.center).lineLimit(2)
                    Text(kind.connectionCaption).font(.caption).foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  if kind.isExperimental {
                    Text(L("实验性")).font(.system(size: 9, weight: .semibold))
                      .padding(.horizontal, 6).padding(.vertical, 2)
                      .foregroundStyle(.orange).background(
                        Color.orange.opacity(0.12), in: Capsule())
                  }
                }
                .padding(10).frame(maxWidth: .infinity).frame(height: 124)
              }
              .buttonStyle(ConnectionCardStyle(selected: selectedKind == kind))
              .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                  selectedKind = kind
                  choose(kind)
                }
              )
              .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
              .accessibilityLabel(kind.title)
              .accessibilityValue(kind.connectionCaption)
              .accessibilityHint(L("双击可直接进入连接设置"))
            }
          }
        }
      }

      if groups.isEmpty {
        ContentUnavailableView(
          L("没有匹配的位置类型"), systemImage: "magnifyingglass",
          description: Text(L("换个关键词试试"))
        )
        .frame(maxWidth: .infinity).padding(.vertical, 24)
      }
    }
  }

  private var connectionForm: some View {
    VStack(alignment: .leading, spacing: 20) {
      editorSection(L("基本信息")) {
        requiredNameField
        colorChoices
      }
      editorSection(L("连接信息")) { connectionFields }
      preparationGuide
      if draft.kind.usesSystemMount {
        editorSection(L("连接选项")) {
          Toggle(L("打开 App 时自动挂载"), isOn: $draft.autoMount)
          Toggle(L("挂载后自动在 Finder 中打开"), isOn: $draft.openInFinderAfterMount)
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let error {
        let canReauthenticate =
          draft.kind.usesOAuthCloud || draft.kind == .pikPak || draft.kind == .tianyiDrive
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
          Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button(canReauthenticate ? L("重新登录") : L("重试")) {
            if canReauthenticate {
              model.forceLogin = true
            }
            save()
          }.controlSize(.small).disabled(busy)
          Button(L("复制详细信息")) { copy(error) }.controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }
      HStack(spacing: 10) {
        if chosen && model.editing == nil {
          Button(L("上一步")) {
            chosen = false
            selectedKind = draft.kind == .androidWiFi ? .androidUSB : draft.kind
            error = nil
          }
        }
        if busy, let stage {
          ProgressView().controlSize(.small)
          Text(stage).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(L("取消")) {
          if busy {
            cancelWork()
          } else {
            dismissWindow(id: "connection")
          }
        }.keyboardShortcut(.cancelAction)
        if chosen {
          Button(L("测试并保存"), action: save)
            .buttonStyle(FlatButtonStyle(prominent: true))
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        } else {
          Button(L("下一步")) {
            guard let selectedKind else { return }
            choose(selectedKind)
          }
          .buttonStyle(FlatButtonStyle(prominent: true))
          .disabled(selectedKind == nil)
          .keyboardShortcut(.defaultAction)
        }
      }
    }.padding(.horizontal, 24).padding(.vertical, 16)
  }

  private var requiredNameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldTitle(L("显示名称"), required: true)
      TextField(L("例如：我的手机"), text: $draft.name)
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft.name) { touchedFields.insert("name") }
      if touchedFields.contains("name") && draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
        validationText(L("请填写显示名称"))
      }
    }
  }

  private var colorChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L("图标颜色")).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        ForEach(colors) { choice in
          Button {
            draft.color = choice.value
          } label: {
            Circle().fill(choice.color).frame(width: 24, height: 24)
              .overlay {
                if draft.color == choice.value {
                  Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                }
              }
              .overlay {
                Circle().strokeBorder(
                  draft.color == choice.value ? Color.primary : Color.clear, lineWidth: 2
                )
                .padding(-3)
              }
          }
          .buttonStyle(.plain)
          .help(choice.title).accessibilityLabel(choice.title)
        }
      }
    }
  }

  @ViewBuilder private var connectionFields: some View {
    switch draft.kind {
    case .androidUSB:
      androidModePicker
      devicePicker
    case .androidWiFi:
      androidModePicker
      wirelessFields
    case .ricohGR, .cameraUSB:
      cameraFields
    case .smb:
      smbFields
    case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
      .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      cloudFields
    case .webdav, .webdavHTTPS:
      serverFields
    case .nfs:
      nfsFields
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      objectStorageFields
    }
  }

  private var androidModePicker: some View {
    editorField(L("连接方式")) {
      Picker(L("连接方式"), selection: $draft.kind) {
        Text(L("USB 数据线")).tag(ConnectionKind.androidUSB)
        Text(L("无线调试")).tag(ConnectionKind.androidWiFi)
      }.pickerStyle(.segmented)
    }
  }

  @ViewBuilder private var devicePicker: some View {
    if model.usbDevices.isEmpty {
      inlineEmptyState(
        symbol: "cable.connector.slash", title: L("没有发现安卓手机"),
        detail: L("请打开 USB 调试并检查数据线，然后重新连接。"))
    } else {
      editorField(
        L("安卓设备"), required: true,
        error: requiredError("serial", L("请选择安卓设备"))
      ) {
        Picker(L("安卓设备"), selection: parameter("serial")) {
          Text(L("请选择")).tag("")
          ForEach(model.usbDevices) { device in
            Text(device.name + " · " + device.serial).tag(device.serial)
          }
        }
      }
    }
  }

  private var wirelessFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      let pairingDevices = model.wirelessDevices.filter { $0.type == .pairing }
      if draft.params["guid"] != nil {
        Label(L("这台手机已配对，可以直接测试连接。"), systemImage: "checkmark.circle.fill")
          .font(.callout).foregroundStyle(KayoiTheme.accent)
      } else if pairingDevices.isEmpty {
        inlineEmptyState(
          symbol: "wifi.slash", title: L("没有找到配对服务"),
          detail: L("请在手机上打开无线调试，并选择“使用配对码配对设备”。"))
      } else {
        editorField(
          L("配对设备"), required: true,
          error: requiredError("pairingID", L("请选择配对设备"))
        ) {
          Picker(
            L("配对设备"),
            selection: Binding(
              get: { pairingID },
              set: {
                pairingID = $0
                touchedFields.insert("pairingID")
              })
          ) {
            Text(L("请选择")).tag("")
            ForEach(pairingDevices) { device in
              Text(device.name).tag(device.id)
            }
          }
        }
        editorField(
          L("六位配对码"), required: true,
          error: requiredError("pairingCode", L("请输入六位配对码"))
        ) {
          HStack {
            TextField(L("输入手机显示的六位数字"), text: $pairingCode)
              .textContentType(.oneTimeCode)
            if busy && stage == L("正在配对…") { ProgressView().controlSize(.small) }
          }
        }
        if error != nil, draft.params["guid"] == nil {
          Button(L("重新输入")) {
            self.error = nil
            pairingCode = ""
            pairingTask = nil
          }.controlSize(.small)
        }
      }
    }
  }

  @ViewBuilder private var cameraFields: some View {
    if draft.kind == .ricohGR {
      if model.ricohDevices.isEmpty {
        inlineEmptyState(
          symbol: "camera.badge.ellipsis", title: L("没有发现理光相机"),
          detail: L("请用数据线连接 GR IV，并退出正在占用相机的 App。"))
      } else {
        editorField(
          L("理光相机"), required: true,
          error: requiredError("serial", L("请选择理光相机"))
        ) {
          Picker(L("理光相机"), selection: parameter("serial")) {
            Text(L("请选择")).tag("")
            ForEach(model.ricohDevices) { device in
              Text(device.name + " · " + device.serial).tag(device.serial)
            }
          }
        }
      }
    } else {
      if model.cameraUSBDevices.isEmpty {
        inlineEmptyState(
          symbol: "camera.badge.ellipsis", title: L("没有发现相机"),
          detail: L("请用数据线连接相机，并退出正在占用相机的 App。"))
      } else {
        editorField(
          L("相机"), required: true,
          error: requiredError("serial", L("请选择相机"))
        ) {
          Picker(L("相机"), selection: parameter("serial")) {
            Text(L("请选择")).tag("")
            ForEach(model.cameraUSBDevices) { device in
              Text(device.name + " · " + device.serial).tag(device.serial)
            }
          }
        }
      }
    }
  }

  private var smbFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      editorField(
        L("主机地址"), required: true,
        error: requiredError("host", L("请填写主机地址"))
      ) {
        TextField(L("192.168.1.10 或 DESKTOP-PC"), text: parameter("host"))
      }
      Toggle(L("使用访客登录"), isOn: $guestLogin)
      if !guestLogin {
        editorField(
          L("用户名"), required: true,
          error: requiredError("username", L("请填写用户名"))
        ) { TextField(L("账户名或邮箱"), text: parameter("username")) }
        passwordField()
      }
      if shares.isEmpty {
        HStack(alignment: .bottom, spacing: 8) {
          editorField(
            L("共享名"), required: true,
            error: requiredError("share", L("请填写共享名"))
          ) {
            TextField(L("共享文件夹名称"), text: parameter("share"))
          }
          Button(L("列出共享"), action: listShares)
            .fixedSize().disabled(
              busy || (draft.params["host"] ?? "").isEmpty
                || (!guestLogin && (draft.params["username"] ?? "").isEmpty))
        }
      } else {
        editorField(
          L("选择共享"), required: true,
          error: requiredError("share", L("请选择共享"))
        ) {
          Picker(L("选择共享"), selection: parameter("share")) {
            Text(L("请选择")).tag("")
            ForEach(shares, id: \.self) { Text($0).tag($0) }
          }
        }
        Button(L("重新输入共享名")) { shares = [] }.controlSize(.small)
      }
    }
  }

  private func passwordField(label: String = L("密码")) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldTitle(label)
      HStack {
        Group {
          if passwordVisible {
            TextField(label, text: $password)
          } else {
            SecureField(label, text: $password)
              .onChange(of: password) { touchedFields.insert("password") }
          }
        }.textFieldStyle(.roundedBorder)
        Button {
          passwordVisible.toggle()
        } label: {
          Image(systemName: passwordVisible ? "eye.slash" : "eye")
        }
        .buttonStyle(.plain).accessibilityLabel(
          passwordVisible ? L("隐藏密码") : L("显示密码"))
      }
    }
  }

  private func secretField(
    _ title: String, placeholder: String, field: String, required: Bool = false,
    error: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldTitle(title, required: required)
      SecureField(placeholder, text: $password)
        .textFieldStyle(.roundedBorder)
        .onChange(of: password) { touchedFields.insert(field) }
      if let error, requiredError(field, error) != nil { validationText(error) }
    }
  }

  @ViewBuilder private var cloudFields: some View {
    switch draft.kind {
    case .quark, .ucDrive:
      webCookieCloudFields
    case .pikPak:
      pikPakFields
    case .tianyiDrive:
      tianyiFields
    case .lanzou:
      lanzouFields
    case .mobileCloud, .thunderDrive:
      chinaTokenFields
    default:
      oauthCloudFields
    }
  }

  private var oauthCloudFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(
        detail: L("使用服务商官方授权，登录信息只保存在钥匙串。")
      ) {
        model.forceLogin = true
        save()
      }
      if draft.kind.usesCloudDriveOAuth, !model.oauthIsConfigured(for: draft.kind) {
        Label(L("此网盘尚未在 Kayoi 中启用"), systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      if draft.kind == .baiduDrive {
        Label(
          L("百度网盘只允许访问此应用的专属目录；非会员可能受到速度和文件大小限制，下载会按服务商要求使用指定客户端标识。"),
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var webCookieCloudFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(
        detail: draft.kind == .ucDrive
          ? L("UC 网盘使用网页登录，接口可能随时失效。")
          : L("夸克网盘使用网页登录，接口可能随时失效。")
      ) {
        model.forceLogin = true
        save()
      }
    }
  }

  private var pikPakFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(detail: L("PikPak 使用账号密码登录，接口可能随时失效。")) {
        resetManualLogin()
      }
      if needsManualCredential {
        editorField(
          L("账号或邮箱"), required: true,
          error: requiredError("username", L("请填写 PikPak 账号或邮箱"))
        ) {
          TextField(L("账号或邮箱"), text: parameter("username"))
        }
        passwordField(label: L("密码"))
      }
    }
  }

  private var tianyiFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(detail: L("天翼云盘使用网页登录信息，接口可能随时失效。")) {
        resetManualLogin()
      }
      editorField(L("空间")) {
        Picker(L("空间"), selection: parameter("scope")) {
          Text(L("个人云")).tag("personal")
          Text(L("家庭云")).tag("family")
        }
        .onChange(of: draft.params["scope"]) { _, value in
          tianyiFamilySpaces = []
          if value == "personal" { draft.params.removeValue(forKey: "familyID") }
        }
      }
      if needsManualCredential {
        secretField(
          L("登录信息"), placeholder: L("从已登录的天翼云盘网页复制登录信息"),
          field: "password", required: true, error: L("请填写天翼云盘登录信息"))
      }
      if draft.params["scope"] == "family" {
        if tianyiFamilySpaces.isEmpty {
          editorField(L("家庭云 ID")) {
            TextField(L("首次登录后会自动读取"), text: parameter("familyID"))
          }
        } else {
          editorField(L("家庭云")) {
            Picker(L("家庭云"), selection: parameter("familyID")) {
              ForEach(tianyiFamilySpaces, id: \.familyID) {
                Text($0.name).tag($0.familyID)
              }
            }
          }
        }
      }
    }
  }

  private var lanzouFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(detail: L("蓝奏云以只读方式浏览，接口可能随时失效。")) {
        resetManualLogin()
      }
      editorField(L("访问方式")) {
        Picker(L("访问方式"), selection: parameter("authMode")) {
          Text(L("账号登录信息")).tag("account")
          Text(L("公开分享链接")).tag("share")
        }
      }
      if draft.params["authMode"] == "share" {
        editorField(
          L("分享链接"), required: true,
          error: requiredError("shareURL", L("请填写蓝奏云分享链接"))
        ) {
          TextField("https://pan.lanzoui.com/…", text: parameter("shareURL"))
        }
        secretField(L("分享密码（可选）"), placeholder: L("没有密码可留空"), field: "password")
      } else {
        secretField(
          L("账号登录信息"), placeholder: L("从已登录的蓝奏云网页复制登录信息"),
          field: "password", required: true, error: L("请填写蓝奏云登录信息"))
      }
    }
  }

  private var chinaTokenFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      cloudAccountHeader(
        detail: draft.kind == .thunderDrive
          ? L("迅雷云盘支持浏览、上传和整理文件，接口可能随时失效。")
          : L("移动云盘使用网页登录信息，接口可能随时失效。")
      ) {
        resetManualLogin()
      }
      if draft.kind == .mobileCloud {
        editorField(
          L("手机号"), required: true,
          error: requiredError("phone", L("请填写移动云盘账号手机号"))
        ) {
          TextField(L("手机号"), text: parameter("phone"))
        }
      }
      secretField(
        draft.kind == .mobileCloud ? L("网页登录令牌") : L("访问令牌"),
        placeholder: L("从已登录网页的登录信息中复制"),
        field: "password", required: true,
        error: L("请填写登录令牌"))
      if draft.kind == .mobileCloud {
        editorField(L("用户域 ID（可选）")) {
          TextField(L("用于容量查询"), text: parameter("userDomainID"))
        }
      }
      if draft.kind == .thunderDrive {
        Label(
          L("上传使用迅雷提供的阿里云 OSS 临时凭据，并由官方 SDK 分片传输。"),
          systemImage: "info.circle"
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func cloudAccountHeader(
    detail: String, switchAccount: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      accountAvatar
      VStack(alignment: .leading, spacing: 2) {
        Text(draft.params["nickname"] ?? L("尚未登录"))
          .font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if draft.params["nickname"] != nil {
        Button(L("切换账号"), action: switchAccount).controlSize(.small)
      }
    }
  }

  private var needsManualCredential: Bool {
    model.forceLogin || draft.params["accountReady"] != "true"
  }

  @ViewBuilder private var accountAvatar: some View {
    if !model.options.isDemo, let value = draft.params["avatarURL"], let url = URL(string: value) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        ProgressView().controlSize(.small)
      }
      .frame(width: 34, height: 34)
      .clipShape(Circle())
      .accessibilityHidden(true)
    } else {
      Image(systemName: "person.crop.circle.fill")
        .font(.title2)
        .foregroundStyle(draft.tint)
        .accessibilityHidden(true)
    }
  }

  private var serverFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      editorField(L("服务预设")) {
        Picker(L("服务预设"), selection: $webdavPreset) {
          ForEach(webdavPresets) { preset in
            Text(preset.title).tag(preset.value)
          }
        }
        .onChange(of: webdavPreset) { _, value in
          guard let preset = webdavPresets.first(where: { $0.value == value }),
            !preset.address.isEmpty
          else { return }
          draft.kind = preset.secure ? .webdavHTTPS : .webdav
          draft.params["url"] = preset.address
        }
      }
      editorField(
        L("服务器地址"), required: true,
        error: requiredError("url", L("请填写服务器地址"))
      ) {
        TextField(
          draft.kind == .webdavHTTPS ? "https://example.com/dav" : "http://example.com/dav",
          text: parameter("url"))
      }
      editorField(L("用户名")) { TextField(L("账户名"), text: parameter("username")) }
      editorField(L("密码")) { SecureField(L("密码"), text: $password) }
      if draft.kind == .webdav {
        Label(L("未加密的 WebDAV 会让密码和文件在局域网中明文传输。"), systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  private var nfsFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      editorField(
        L("服务器地址"), required: true,
        error: requiredError("host", L("请填写服务器地址"))
      ) {
        TextField("192.168.1.10", text: parameter("host"))
      }
      editorField(
        L("导出路径"), required: true,
        error: requiredError("path", L("请填写导出路径"))
      ) {
        TextField("/volume/share", text: parameter("path"))
      }
    }
  }

  private var objectStorageFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      editorField(
        L("服务地址"), required: true,
        error: requiredError("endpoint", L("请填写服务地址"))
      ) {
        TextField("s3.example.com", text: parameter("endpoint"))
      }
      editorField(L("区域")) { TextField("us-east-1", text: parameter("region")) }
      editorField(
        L("存储桶"), required: true,
        error: requiredError("bucket", L("请填写存储桶名称"))
      ) {
        TextField(L("存储桶名称"), text: parameter("bucket"))
      }
      editorField(
        L("访问密钥"), required: true,
        error: requiredError("accessKey", L("请填写访问密钥"))
      ) {
        TextField(L("Access Key ID"), text: parameter("accessKey"))
      }
      editorField(
        L("私密密钥"), required: true,
        error: requiredError("password", L("请填写私密密钥"))
      ) {
        SecureField(L("Secret Access Key"), text: $password)
          .onChange(of: password) { touchedFields.insert("password") }
      }
    }
  }

  private var preparationGuide: some View {
    DisclosureGroup(isExpanded: $preparationExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(preparationSteps, id: \.self) { step in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5))
              .foregroundStyle(KayoiTheme.accent).padding(.top, 6)
            Text(step).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }.padding(.top, 8)
    } label: {
      Label(L("准备步骤"), systemImage: "questionmark.circle")
        .font(.subheadline.weight(.medium))
    }
    .padding(14)
    .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 10))
  }

  private var preparationSteps: [String] {
    switch draft.kind {
    case .androidUSB:
      [L("打开手机的开发者选项"), L("打开 USB 调试"), L("连接数据线并允许这台 Mac")]
    case .androidWiFi:
      [
        L("打开无线调试"), L("选择“使用配对码配对设备”"),
        L("输入手机上显示的六位数字"),
      ]
    case .smb:
      [L("开启文件和打印机共享"), L("给账户读写权限"), L("微软账户的密码不是 PIN")]
    case .ricohGR, .cameraUSB:
      [
        L("用数据线连接相机"), L("退出图像捕捉等正在占用相机的 App"),
        L("在相机上允许访问存储卡"),
      ]
    case .webdav, .webdavHTTPS:
      [L("确认 WebDAV 地址和路径"), L("部分服务需要单独生成应用密码")]
    case .nfs:
      [L("确认 NFS 导出路径和允许访问的客户端")]
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      [L("创建存储桶"), L("创建只允许目标存储桶的访问密钥")]
    case .baiduDrive:
      [
        L("授权后会进入此应用的专属目录"),
        L("非会员账号可能受到下载速度和文件大小限制"),
        L("下载会按服务商要求使用指定客户端标识"),
      ]
    case .pikPak:
      [L("准备 PikPak 账号和密码"), L("账号可能触发验证码保护，请先在官方网页确认账号可登录")]
    case .tianyiDrive:
      [
        L("在浏览器登录天翼云盘"), L("从已登录网页复制 cloud.189.cn 的登录信息"),
        L("选择个人云或家庭云"),
      ]
    case .mobileCloud:
      [
        L("在浏览器登录移动云盘"), L("从已登录请求中复制手机号和登录令牌"),
      ]
    case .thunderDrive:
      [
        L("在浏览器登录迅雷云盘"), L("从已登录请求中复制访问令牌"),
        L("上传会自动使用迅雷提供的云存储分片服务"),
      ]
    case .lanzou:
      [
        L("账号登录信息访问需要先在浏览器登录蓝奏云"),
        L("公开分享链接可直接添加，有密码时填写分享密码"),
        L("蓝奏云在当前版本中只读"),
      ]
    default:
      [L("准备服务商账号"), L("如果服务商提供应用密码，请优先使用应用密码")]
    }
  }

  private func editorSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.subheadline.weight(.semibold))
      VStack(alignment: .leading, spacing: 14, content: content)
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(KayoiTheme.border) }
    }
  }

  private func editorField<Content: View>(
    _ title: String, required: Bool = false, error: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldTitle(title, required: required)
      content().labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let error { validationText(error) }
    }
  }

  private func fieldTitle(_ title: String, required: Bool = false) -> some View {
    HStack(spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if required { Text("*").font(.caption).foregroundStyle(.red) }
    }
  }

  private func validationText(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.circle.fill")
      .font(.caption).foregroundStyle(.red)
  }

  private func requiredError(_ field: String, _ message: String) -> String? {
    guard touchedFields.contains(field) else { return nil }
    let value = DraftValue.value(
      field, draft: draft, pairingID: pairingID, pairingCode: pairingCode, password: password)
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message : nil
  }

  private func inlineEmptyState(symbol: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }.padding(12).background(KayoiTheme.background, in: RoundedRectangle(cornerRadius: 8))
  }

  private var canSave: Bool {
    Validation.requiredFields(
      draft: draft, pairingCode: pairingCode, guest: guestLogin, forceLogin: model.forceLogin
    ).allSatisfy { field in
      let value = DraftValue.value(
        field, draft: draft, pairingID: pairingID, pairingCode: pairingCode, password: password)
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func choose(_ kind: ConnectionKind) {
    let previousKind = draft.kind
    draft.kind = kind
    let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if currentName.isEmpty || draft.name == previousKind.defaultName {
      draft.name = kind.defaultName
    }
    if kind == .lanzou, draft.params["authMode"] == nil {
      draft.params["authMode"] = "account"
    }
    if kind == .tianyiDrive, draft.params["scope"] == nil {
      draft.params["scope"] = "personal"
    }
    if kind == .androidUSB { autoSelectDevice() }
    applyObjectStorageDefaults(for: kind, previousKind: previousKind)
    chosen = true
    error = nil
    touchedFields.removeAll()
  }

  private func applyObjectStorageDefaults(for kind: ConnectionKind, previousKind: ConnectionKind) {
    guard draft.params["endpoint"] == nil || previousKind != kind else { return }
    let defaults: (String, String, Bool)?
    switch kind {
    case .s3: defaults = ("https://s3.us-east-1.amazonaws.com", "us-east-1", false)
    case .cloudflareR2:
      defaults = ("https://ACCOUNT_ID.r2.cloudflarestorage.com", "auto", false)
    case .aliyunOSS: defaults = ("https://s3.oss-cn-hangzhou.aliyuncs.com", "cn-hangzhou", false)
    case .tencentCOS:
      defaults = ("https://cos.ap-guangzhou.myqcloud.com", "ap-guangzhou", false)
    case .qiniuKodo: defaults = ("https://s3.cn-east-1.qiniucs.com", "cn-east-1", false)
    case .minIO: defaults = ("https://minio.example.com", "us-east-1", true)
    case .backblazeB2:
      defaults = ("https://s3.us-west-004.backblazeb2.com", "us-west-004", true)
    default: defaults = nil
    }
    if let defaults {
      draft.params["endpoint"] = defaults.0
      draft.params["region"] = defaults.1
      draft.params["pathStyle"] = defaults.2 ? "true" : "false"
    }
  }

  private func autoSelectDevice() {
    guard chosen || draft.kind == .androidUSB else { return }
    switch draft.kind {
    case .androidUSB where (draft.params["serial"] ?? "").isEmpty:
      if let device = model.usbDevices.first {
        draft.params["serial"] = device.serial
        autoNameFromDevice()
      }
    case .ricohGR where (draft.params["serial"] ?? "").isEmpty:
      if let device = model.ricohDevices.first {
        draft.params["serial"] = device.serial
        autoNameFromDevice()
      }
    case .cameraUSB where (draft.params["serial"] ?? "").isEmpty:
      if let device = model.cameraUSBDevices.first {
        draft.params["serial"] = device.serial
        autoNameFromDevice()
      }
    case .androidWiFi where pairingID.isEmpty:
      if let device = model.wirelessDevices.first(where: { $0.type == .pairing }) {
        pairingID = device.id
      }
    default:
      break
    }
  }

  private func autoNameFromDevice() {
    guard draft.name.isEmpty || draft.name == draft.kind.defaultName else { return }
    if let serial = draft.params["serial"] {
      if let device = model.usbDevices.first(where: { $0.serial == serial }) {
        draft.name = device.name
      } else if let device = model.ricohDevices.first(where: {
        $0.serial == serial
      }) {
        draft.name = device.name
      } else if let device = model.cameraUSBDevices.first(where: {
        $0.serial == serial
      }) {
        draft.name = device.name
      }
    }
  }

  private func pairWirelessDevice() {
    guard pairingTask == nil,
      let device = model.wirelessDevices.first(where: { $0.id == pairingID }),
      let host = device.host, let port = device.port
    else { return }
    busy = true
    error = nil
    stage = L("正在配对…")
    pairingTask = Task { @MainActor in
      defer {
        busy = false
        stage = nil
        pairingTask = nil
      }
      do {
        let guid = model.options.isDemo ? "adb-demo-ABC123" : try await ADBPairing.pair(host: host, port: port, code: pairingCode)
        try Task.checkCancellation()
        draft.params["guid"] = guid
        draft.params["name"] = draft.name
        pairingCode = ""
      } catch is CancellationError {
      } catch {
        model.connections.reportOperationError(error)
        self.error =
          (error as? PairingError) == .wrongCode
          ? L("配对码错误，请重新输入。") : HumanError.detail(error, kind: draft.kind)
      }
    }
  }

  private func listShares() {
    busy = true
    error = nil
    stage = L("正在读取共享列表…")
    shareTask = Task { @MainActor in
      defer {
        busy = false
        stage = nil
        shareTask = nil
      }
      do {
        shares = try await model.connections.listShares(
          host: draft.params["host"] ?? "",
          user: guestLogin ? "" : draft.params["username"] ?? "",
          password: guestLogin ? "" : password)
        try Task.checkCancellation()
        if shares.isEmpty {
          error = L("没有找到可访问的共享，请检查权限或手动填写共享名。")
        } else if let first = shares.first {
          draft.params["share"] = first
        }
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled {
          self.error = HumanError.detail(error, kind: draft.kind)
        }
      }
    }
  }

  private func save() {
    guard !busy else { return }
    busy = true
    error = nil
    saving = Task { @MainActor in
      defer {
        busy = false
        stage = nil
        saving = nil
      }
      do {
        if model.options.isDemo {
          stage = L("正在测试连接…")
          try await model.connections.save(draft, password: password)
          model.forceLogin = false
          dismissWindow(id: "connection")
          return
        }
        if draft.kind == .androidWiFi && draft.params["guid"] == nil {
          stage = L("正在配对…")
          guard let device = model.wirelessDevices.first(where: { $0.id == pairingID }),
            let host = device.host, let port = device.port
          else { throw RemoteError.notConnected }
          draft.params["guid"] = try await ADBPairing.pair(
            host: host, port: port, code: pairingCode)
          draft.params["name"] = draft.name
          pairingCode = ""
        }
        try Task.checkCancellation()
        if draft.kind == .aliyunDrive {
          stage = model.forceLogin ? L("等待浏览器授权…") : L("正在验证账号…")
          let session = model.aliyunSession(for: draft)
          guard AppModel.aliyunConfiguration.isConfigured else {
            throw AliyunError.missingConfiguration
          }
          let hasToken = try await session.hasToken()
          if model.forceLogin || !hasToken {
            stage = L("等待浏览器授权…")
            let state = UUID().uuidString
            let url = try await session.authorizationURL(state: state)
            guard
              let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "redirect_uri" })?.value,
              let window = NSApplication.shared.keyWindow
            else { throw OAuthCallbackError.invalid }
            let authorization = WebAuthorization(window: window)
            webAuthorization = authorization
            let callback = try await authorization.authorize(url)
            try Task.checkCancellation()
            let code = try OAuthCallback.code(
              from: callback, redirectURI: redirect, state: state)
            try await session.exchange(code: code)
          }
          let account = try await session.account()
          draft.params["nickname"] = account.nickname
          draft.params["userID"] = account.userID
          if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = account.nickname
          }
        }
        if draft.kind.usesCloudDriveOAuth {
          stage = model.forceLogin ? L("等待浏览器授权…") : L("正在验证账号…")
          guard model.oauthIsConfigured(for: draft.kind) else {
            throw OAuthDriveError.configuration
          }
          let session = try model.oauthSession(for: draft)
          let hasToken = try await session.hasToken()
          if model.forceLogin || !hasToken {
            stage = L("等待浏览器授权…")
            let state = UUID().uuidString
            let url = try await session.authorizationURL(state: state)
            guard
              let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "redirect_uri" })?.value,
              let window = NSApplication.shared.keyWindow
            else { throw OAuthCallbackError.invalid }
            let authorization = WebAuthorization(window: window)
            webAuthorization = authorization
            let callback = try await authorization.authorize(url)
            try Task.checkCancellation()
            let code = try OAuthCallback.code(
              from: callback, redirectURI: redirect, state: state)
            try await session.exchange(code: code)
          }
          let profile = try await model.oauthProfile(for: draft)
          draft.params["nickname"] = profile.nickname
          draft.params["userID"] = profile.userID
          draft.params["avatarURL"] = profile.avatarURL
          if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.name == draft.kind.defaultName
          {
            draft.name = profile.nickname
          }
        }
        if draft.kind == .quark || draft.kind == .ucDrive {
          stage = model.forceLogin ? L("等待网页登录…") : L("正在验证账号…")
          let session = QuarkSession(
            secretKey: "\(draft.id.uuidString).cookie",
            configuration: draft.kind == .ucDrive ? .uc : .quark)
          let hasCookie = try await session.hasCookie()
          let account: QuarkAccount
          if model.forceLogin || !hasCookie {
            stage = L("等待网页登录…")
            account = try await loginQuark(session)
          } else {
            account = try await session.account()
          }
          draft.params["nickname"] = account.nickname
          draft.params["userID"] = account.userID
          if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = account.nickname
          }
        }
        if draft.kind == .pikPak {
          stage = model.forceLogin ? L("等待 PikPak 登录…") : L("正在验证账号…")
          let session = model.pikPakSession(for: draft)
          let hasToken = try await session.hasToken()
          let account: PikPakAccount
          if model.forceLogin || !hasToken {
            stage = L("正在登录 PikPak…")
            account = try await session.login(
              username: draft.params["username"] ?? "", password: password)
          } else {
            account = try await session.account()
          }
          draft.params["nickname"] = account.nickname.isEmpty ? account.email : account.nickname
          draft.params["userID"] = account.userID
          draft.params["accountReady"] = "true"
          if draft.name == draft.kind.defaultName, !account.nickname.isEmpty {
            draft.name = account.nickname
          }
        }
        if draft.kind == .tianyiDrive {
          stage = model.forceLogin ? L("等待天翼云盘登录…") : L("正在验证账号…")
          let authSession = TianyiSession(
            secretKey: "\(draft.id.uuidString).oauth.tianyiDrive", configuration: .personal)
          let hasLogin = try await authSession.hasLogin()
          if model.forceLogin || !hasLogin {
            guard !password.isEmpty else { throw TianyiError.invalidCookie }
            _ = try await authSession.login(cookie: password)
          }
          if draft.params["scope"] == "family" {
            let spaces = try await authSession.familySpaces()
            tianyiFamilySpaces = spaces
            if (draft.params["familyID"] ?? "").isEmpty {
              if spaces.count == 1 {
                draft.params["familyID"] = spaces[0].familyID
              } else {
                throw TianyiError.invalidFamilyID
              }
            }
          }
          let session = model.tianyiSession(for: draft)
          let account = try await session.account()
          draft.params["nickname"] =
            account.displayName.isEmpty ? account.userID : account.displayName
          draft.params["userID"] = account.userID
          draft.params["accountReady"] = "true"
          if draft.name == draft.kind.defaultName, !account.displayName.isEmpty {
            draft.name = account.displayName
          }
        }
        if draft.kind == .lanzou, draft.params["authMode"] == "share", password.isEmpty {
          try LoginKeychainStore().delete(draft.passwordKey)
        }
        if draft.kind == .smb {
          draft.params["guest"] = guestLogin ? "true" : nil
        }
        try Task.checkCancellation()
        switch draft.kind {
        case .androidUSB, .androidWiFi:
          stage = L("等待手机授权…")
        case .ricohGR, .cameraUSB:
          stage = L("等待相机响应…")
        default:
          stage = L("正在测试连接…")
        }
        try await model.connections.save(
          draft, password: guestLogin && draft.kind == .smb ? "" : password)
        model.forceLogin = false
        dismissWindow(id: "connection")
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled {
          model.connections.reportOperationError(error)
          self.error = HumanError.detail(error, kind: draft.kind)
        }
      }
    }
  }

  private func loginQuark(_ session: QuarkSession) async throws -> QuarkAccount {
    quarkSession = session
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<QuarkAccount, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        quarkContinuation = continuation
        showQuarkLogin = true
      }
    } onCancel: {
      Task { @MainActor in
        finishQuark(.failure(CancellationError()))
      }
    }
  }

  private func finishQuark(_ result: Result<QuarkAccount, Error>) {
    guard let continuation = quarkContinuation else { return }
    quarkContinuation = nil
    showQuarkLogin = false
    quarkSession = nil
    continuation.resume(with: result)
  }

  private func cancelWork() {
    saving?.cancel()
    pairingTask?.cancel()
    shareTask?.cancel()
    webAuthorization?.cancel()
    finishQuark(.failure(CancellationError()))
    model.forceLogin = false
    tianyiFamilySpaces = []
    webAuthorization = nil
    quarkSession = nil
    busy = false
    stage = nil
    saving = nil
    pairingTask = nil
    shareTask = nil
  }

  private func resetManualLogin() {
    model.forceLogin = true
    draft.params.removeValue(forKey: "accountReady")
    draft.params.removeValue(forKey: "nickname")
    password = ""
    touchedFields.removeAll()
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func parameter(_ key: String) -> Binding<String> {
    Binding(
      get: { draft.params[key] ?? "" },
      set: {
        draft.params[key] = $0
        touchedFields.insert(key)
      })
  }
}

private enum Validation {
  static func requiredFields(
    draft: Connection, pairingCode: String, guest: Bool, forceLogin: Bool
  ) -> [String] {
    switch draft.kind {
    case .androidUSB: ["name", "serial"]
    case .androidWiFi:
      draft.params["guid"] == nil ? ["name", "pairingID", "pairingCode"] : ["name"]
    case .ricohGR, .cameraUSB: ["name", "serial"]
    case .smb: guest ? ["name", "host", "share"] : ["name", "host", "username", "share"]
    case .webdav, .webdavHTTPS: ["name", "url"]
    case .nfs: ["name", "host", "path"]
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      ["name", "endpoint", "bucket", "accessKey", "password"]
    case .pikPak:
      forceLogin || draft.params["accountReady"] != "true"
        ? ["name", "username", "password"] : ["name"]
    case .tianyiDrive:
      forceLogin || draft.params["accountReady"] != "true"
        ? ["name", "password"] : ["name"]
    case .lanzou:
      if draft.params["authMode"] == "share" {
        ["name", "shareURL"]
      } else {
        ["name", "password"]
      }
    case .mobileCloud: ["name", "phone", "password"]
    case .thunderDrive: ["name", "password"]
    default: ["name"]
    }
  }
}

private enum DraftValue {
  static func value(
    _ field: String, draft: Connection, pairingID: String, pairingCode: String, password: String
  ) -> String {
    switch field {
    case "name": draft.name
    case "pairingID": pairingID
    case "pairingCode": pairingCode
    case "password": password
    default: draft.params[field] ?? ""
    }
  }
}

extension AliyunConfiguration {
  fileprivate var isConfigured: Bool {
    !clientID.isEmpty && !clientSecret.isEmpty && URL(string: redirectURI)?.scheme == "kayoi"
  }
}

extension ConnectionKind {
  var title: String {
    switch self {
    case .androidUSB: L("安卓手机")
    case .androidWiFi: L("安卓手机（无线）")
    case .smb: L("SMB 共享（Windows / Mac / NAS）")
    case .ricohGR: L("理光 GR IV")
    case .cameraUSB: L("相机（USB）")
    case .webdav: L("WebDAV")
    case .webdavHTTPS: L("WebDAV over HTTPS")
    case .nfs: L("NFS")
    case .s3: L("Amazon S3")
    case .cloudflareR2: L("Cloudflare R2")
    case .aliyunOSS: L("阿里云 OSS")
    case .tencentCOS: L("腾讯云 COS")
    case .qiniuKodo: L("七牛 Kodo")
    case .minIO: L("MinIO")
    case .backblazeB2: L("Backblaze B2")
    case .aliyunDrive: L("阿里云盘")
    case .quark: L("夸克网盘")
    case .baiduDrive: L("百度网盘")
    case .drive115: L("115 网盘")
    case .drive123: L("123 云盘")
    case .oneDrive: L("OneDrive")
    case .googleDrive: L("Google Drive")
    case .dropbox: L("Dropbox")
    case .ucDrive: L("UC 网盘")
    case .tianyiDrive: L("天翼云盘")
    case .mobileCloud: L("移动云盘")
    case .thunderDrive: L("迅雷云盘")
    case .pikPak: L("PikPak")
    case .lanzou: L("蓝奏云")
    }
  }
  var defaultName: String {
    switch self {
    case .androidUSB, .androidWiFi: L("我的安卓手机")
    case .smb: L("我的 SMB 共享")
    case .ricohGR: L("我的理光相机")
    case .cameraUSB: L("我的相机")
    default: title
    }
  }
  var isExperimental: Bool {
    switch self {
    case .quark, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou: true
    default: false
    }
  }
  var usesCloudDriveOAuth: Bool {
    switch self {
    case .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox:
      true
    default:
      false
    }
  }
  var usesOAuthCloud: Bool {
    switch self {
    case .aliyunDrive, .quark, .ucDrive:
      true
    default:
      usesCloudDriveOAuth
    }
  }
}
