import ADB
import AliyunDrive
import Core
import Quark
import RicohGR
import SwiftUI

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
  @State private var showQuarkLogin = false
  @State private var quarkSession: QuarkSession?
  @State private var quarkContinuation: CheckedContinuation<QuarkAccount, Error>?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.editing == nil ? L("添加位置") : L("编辑位置")).font(.title2.bold())
      if !chosen {
        Text("选择位置类型").foregroundStyle(.secondary)
        ForEach(ConnectionKind.allCases.filter { $0 != .androidWiFi }, id: \.self) { kind in
          Button {
            draft.kind = kind
            chosen = true
          } label: {
            HStack {
              Text(kind == .androidUSB ? L("安卓手机") : kind.title)
              Spacer()
              Image(systemName: "chevron.right")
            }.frame(maxWidth: .infinity)
          }
        }
      } else {
        Form {
          TextField("显示名称", text: $draft.name)
          Picker("图标颜色", selection: $draft.color) {
            Text("蓝色").tag("blue")
            Text("绿色").tag("green")
            Text("橙色").tag("orange")
            Text("红色").tag("red")
          }
          if draft.kind == .androidUSB || draft.kind == .androidWiFi {
            Picker("连接方式", selection: $draft.kind) {
              Text("USB").tag(ConnectionKind.androidUSB)
              Text("Wi-Fi").tag(ConnectionKind.androidWiFi)
            }
          }
          if draft.kind == .androidUSB {
            Picker("安卓设备", selection: parameter("serial")) {
              Text("请选择").tag("")
              ForEach(model.usbDiscovery.devices) { device in
                Text(device.name + " · " + device.serial).tag(device.serial)
              }
            }
          } else if draft.kind == .ricohGR {
            Picker("GR IV 相机", selection: parameter("serial")) {
              Text("请选择").tag("")
              ForEach(model.ricohDiscovery.devices) { device in
                Text(device.name + " · " + device.serial).tag(device.serial)
              }
            }
          } else if draft.kind == .androidWiFi {
            Picker("配对设备", selection: $pairingID) {
              Text("请选择").tag("")
              ForEach(model.wirelessDiscovery.devices.filter { $0.type == .pairing }) { device in
                Text(device.name).tag(device.id)
              }
            }
            SecureField("六位配对码", text: $pairingCode)
            if draft.params["guid"] != nil {
              Text("已配对时可留空，直接测试连接。").font(.caption).foregroundStyle(.secondary)
            }
          } else if draft.kind == .quark {
            Text("保存时打开夸克扫码登录，也可手动粘贴 Cookie。").font(.caption).foregroundStyle(.secondary)
            if let nickname = draft.params["nickname"] { LabeledContent("账号", value: nickname) }
          } else if draft.kind == .aliyunDrive {
            Text("保存时将打开阿里云盘官方授权页。").font(.caption).foregroundStyle(.secondary)
            if let nickname = draft.params["nickname"] { LabeledContent("账号", value: nickname) }
          } else {
            TextField("主机 IP 或名称", text: parameter("host"))
            TextField("用户名", text: parameter("username"))
            SecureField("密码", text: $password)
            HStack {
              TextField("共享名", text: parameter("share"))
              Button("列出共享") { listShares() }.disabled(
                busy || (draft.params["host"] ?? "").isEmpty
                  || (draft.params["username"] ?? "").isEmpty)
            }
            if !shares.isEmpty {
              Picker("选择共享", selection: parameter("share")) {
                Text("请选择").tag("")
                ForEach(shares, id: \.self) { Text($0).tag($0) }
              }
            }
          }
          Toggle("打开 App 时自动挂载", isOn: $draft.autoMount)
          Toggle("挂载后自动在 Finder 打开", isOn: $draft.openInFinderAfterMount)
        }.disabled(busy)
        if draft.kind == .androidUSB {
          Text("首次连接请在手机上点允许 USB 调试，最多等待 60 秒。").font(.caption).foregroundStyle(.secondary)
        } else if draft.kind == .ricohGR {
          Text("USB 连接 GR IV，支持原图读取，以及相机允许的删除操作。").font(.caption).foregroundStyle(.secondary)
        } else if draft.kind == .androidWiFi {
          Text("在手机上打开无线调试，再选择“使用配对码配对设备”。Mac 和手机需在同一局域网。").font(.caption).foregroundStyle(
            .secondary)
        } else if draft.kind == .quark {
          Text("非官方接口，可能随时失效").font(.caption).foregroundStyle(.secondary)
        } else if draft.kind == .aliyunDrive {
          Text("需配置开放平台 client_id 和回调地址。第三方挂载权益可能由阿里云盘限制。").font(.caption).foregroundStyle(
            .secondary)
        } else {
          Text("Windows 需开启“文件和打印机共享”。微软账户请填邮箱和账户密码，不能使用 PIN。").font(.caption).foregroundStyle(
            .secondary)
        }
        Text("保存前会测试连接，成功后才保存。").font(.caption).foregroundStyle(.secondary)
      }
      if let error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      HStack {
        if busy {
          ProgressView().controlSize(.small)
          Text("正在测试连接…").font(.caption)
        }
        Spacer()
        Button("取消") { dismissWindow(id: "connection") }.disabled(busy)
        if chosen {
          Button("测试并保存") { save() }.buttonStyle(.borderedProminent).disabled(busy)
            .keyboardShortcut(.defaultAction)
        }
      }
    }.padding(24).frame(width: 460)
      .task {
        draft = model.editing ?? Connection()
        chosen = model.editing != nil
        pairingID = model.pairingSelection ?? ""
        if let connection = model.editing, connection.kind == .smb {
          do { password = try model.connections.savedPassword(connection) } catch {
            model.connections.reportOperationError(error)
            self.error = error.localizedDescription
          }
        }
      }
      .onDisappear {
        finishQuark(.failure(CancellationError()))
        saving?.cancel()
        webAuthorization?.cancel()
      }
      .sheet(
        isPresented: $showQuarkLogin, onDismiss: { finishQuark(.failure(CancellationError())) }
      ) {
        if let session = quarkSession {
          QuarkLoginView(
            session: session, onSuccess: { finishQuark(.success($0)) },
            onCancel: { finishQuark(.failure(CancellationError())) })
        }
      }
      .onChange(of: draft.params["host"]) { shares = [] }
      .onChange(of: draft.params["username"]) { shares = [] }
  }
  private func parameter(_ key: String) -> Binding<String> {
    Binding(get: { draft.params[key] ?? "" }, set: { draft.params[key] = $0 })
  }
  private func listShares() {
    busy = true
    error = nil
    Task { @MainActor in
      defer { busy = false }
      do {
        shares = try await model.connections.listShares(
          host: draft.params["host"] ?? "", user: draft.params["username"] ?? "", password: password
        )
        if shares.isEmpty { error = L("没有可访问的文件共享") }
      } catch { self.error = error.localizedDescription }
    }
  }
  private func loginQuark(_ session: QuarkSession) async throws -> QuarkAccount {
    quarkSession = session
    return try await withCheckedThrowingContinuation { continuation in
      quarkContinuation = continuation
      showQuarkLogin = true
    }
  }
  private func finishQuark(_ result: Result<QuarkAccount, Error>) {
    guard let continuation = quarkContinuation else { return }
    quarkContinuation = nil
    showQuarkLogin = false
    quarkSession = nil
    continuation.resume(with: result)
  }
  private func save() {
    busy = true
    error = nil
    saving = Task { @MainActor in
      defer { busy = false }
      var savingConnection = false
      do {
        if draft.kind == .androidWiFi && (!pairingCode.isEmpty || draft.params["guid"] == nil) {
          guard let device = model.wirelessDiscovery.devices.first(where: { $0.id == pairingID }),
            let host = device.host, let port = device.port
          else { throw RemoteError.notConnected }
          let guid = try await ADBPairing.pair(host: host, port: port, code: pairingCode)
          draft.params = ["guid": guid, "name": draft.name]
          pairingCode = ""
        }
        if draft.kind == .aliyunDrive {
          let session = model.aliyunSession(for: draft)
          let hasToken = try await session.hasToken()
          if model.forceLogin || !hasToken {
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
            let code = try OAuthCallback.code(from: callback, redirectURI: redirect, state: state)
            try await session.exchange(code: code)
          }
          let account = try await session.account()
          draft.params = ["nickname": account.nickname, "userID": account.userID]
          if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = account.nickname
          }
        }
        if draft.kind == .quark {
          let session = QuarkSession(secretKey: "\(draft.id.uuidString).cookie")
          let hasCookie = try await session.hasCookie()
          let account: QuarkAccount
          if model.forceLogin || !hasCookie {
            account = try await loginQuark(session)
          } else {
            account = try await session.account()
          }
          draft.params = ["nickname": account.nickname, "userID": account.userID]
          if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = account.nickname
          }
        }
        savingConnection = true
        try await model.connections.save(draft, password: password)
        model.forceLogin = false
        dismissWindow(id: "connection")
      } catch {
        if !savingConnection { model.connections.reportOperationError(error) }
        self.error = error.localizedDescription
      }
    }
  }
}

extension ConnectionKind {
  var title: String {
    switch self {
    case .androidUSB: L("安卓手机（USB）")
    case .androidWiFi: L("安卓手机（Wi-Fi）")
    case .smb: L("Windows 共享")
    case .ricohGR: L("理光 GR IV")
    case .aliyunDrive: L("阿里云盘")
    case .quark: L("夸克网盘（实验性）")
    }
  }
}
