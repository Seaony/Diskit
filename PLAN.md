# Diskit 实现方案

> 这份文档写给实现者（Codex）。照里程碑顺序做，每个里程碑做完按「验收标准」自证后再进入下一个。
> 分两个阶段：M0–M6 不需要付费开发者账号；M7 起需要（FSKit 扩展）。文中「以 M7 验证结论为准」的地方，先完成 M7 第一步验证、把结论写进 `docs/SPIKE.md`，再按结论实现。

## 0. 一句话定位

macOS 菜单栏 App：点菜单栏图标弹出面板，里面是已保存的「位置」（我的安卓手机、Windows 电脑、理光 GR IV、阿里云盘、夸克网盘……），点一下就把它挂成 Finder 里的一个盘，之后在 Finder 或任何 App 里直接浏览、新增、删除、改名、复制文件。

参考产品：SideMount（菜单栏 + FSKit 文件系统扩展 + 自己实现 adb 协议）、MacDroid（MTP/ADB 挂载）、DroidMount / adbdav（adb + 本地 WebDAV 挂载）。

## 1. 目标与非目标

### 目标

- 菜单栏常驻，无 Dock 图标；面板 UI 风格参考 SideMount（深色、圆角卡片、底部版本号 + 设置/退出，不做帮助页面）。
- 已保存连接的增、删、改、排序；每个连接一键「挂载 / 推出」。
- 支持的位置类型：
  1. 安卓手机：USB 数据线（开了 USB 调试走 ADB；没开时走 MTP 文件传输，插上就能用），局域网 Wi‑Fi（Android 11+ 无线调试）。
  2. Windows 电脑（局域网 SMB 共享）。
  3. 理光 GR IV：USB 数据线；Wi‑Fi 只做技术验证（见 §6.4）。
  4. 阿里云盘（官方开放平台 OAuth）。
  5. 夸克网盘（非官方网页接口，实验性）。
- 挂载后在 Finder 中支持：浏览、读取（含 Quick Look 预览）、新建文件夹、上传（拷入）、下载（拷出）、删除、改名、移动。各类型能力差异见 §4.3。

### 非目标（本期不做）

- 双向同步、自动备份、版本历史。
- 百度网盘、115、OneDrive 等其它网盘（架构要允许以后加，但不预先写）。
- iOS 设备、Windows/Linux 客户端。
- App 内自带的文件浏览器窗口（Finder 就是浏览器；只有 M7 验证否定 FSKit 时才启用备选方案，见 §3.5）。
- 安卓端安装任何配套 App、root。

## 2. 调研结论（实现前必读）

| 位置 | 接入方式 | 可行性 | 主要风险 |
| --- | --- | --- | --- |
| 安卓 USB | 自己用 Swift 实现 ADB 协议，通过 IOKit/IOUSBHost 直接和手机的 ADB USB 接口通信（不依赖 adb 可执行文件） | 高，SideMount 已证明可行 | 同一时刻只能一个进程占用手机 ADB 接口，用户自己的 adb server 会冲突 |
| 安卓 USB（MTP） | 没开 USB 调试的设备（手机、平板、阅读器，如文石 Leaf5 的接口是 0xFF/0xFF、名为 MTP）走 MTP：IOKit/IOUSBHost 直接和 MTP 接口通信，自己实现 PTP/MTP 事务；同一设备开了 USB 调试时优先 ADB | 高，2026-11-26 Leaf5 实测列目录、读取可用（84.5 MB/s） | Android File Transfer 的登录项 Agent 在插上设备时会打开它并独占接口：连接被它挡住时自动让它退出再连。设备空闲时绝不发 MTP Cancel（Leaf5 实测收到后再也不收命令，只能重插；libmtp 也只在传输中途取消时才发）。设备的 MTP 服务还没起来或锁屏时没开放存储：连接时最多等 60 秒，就绪就连上，等不到报具体该做什么；发现阶段问不到型号先显示 USB 产品名，每 10 秒再问，连上后改用设备报的型号 |
| 安卓 Wi‑Fi | Android 11+ 无线调试：mDNS 发现 → 配对码配对（SPAKE2）→ TLS 连接 → 跑同一套 ADB 协议 | 中高 | SPAKE2 配对要用 BoringSSL；首次需要在手机上输入配对码 |
| Windows SMB | 直接用系统 NetFS 挂载 `smb://` | 高，系统原生 | Windows 默认不广播 Bonjour，主要靠手动填 IP/主机名；微软账户要用账户密码而不是 PIN |
| 理光 GR IV USB | 相机走 MTP（零售商规格表写的是 `Data Transfer: MTP`）。用系统 ImageCaptureCore 读取 | 中高 | 能不能被 ImageCaptureCore 识别、能不能删除，要真机验证 |
| 理光 GR IV Wi‑Fi | GR III 有公开的 HTTP 接口 `http://192.168.0.1/v1/photos`；GR IV 机身菜单里没有 Wi‑Fi 开关，只能由 GR WORLD 通过蓝牙唤起 Wi‑Fi，唤起命令没有公开资料 | 低，只做技术验证 | 需要抓包逆向蓝牙命令；Mac 连相机热点时会断开外网 |
| 阿里云盘 | 官方开放平台 `openapi.alipan.com`，OAuth2 授权码 + 刷新令牌 | 中 | 要申请开发者 `client_id`；官方政策对「第三方挂载为本地磁盘」要求用户开通「三方应用权益包」，未开通可能被限速或限制 |
| 夸克网盘 | 没有对个人开放的官方接口。只能用网页版接口 + 扫码登录拿 Cookie（OpenList 的 quark 驱动就是这样做的） | 中低 | 非官方、接口随时变、Cookie 约 30 天失效；OpenList 是 AGPL，只能参考协议行为，不能抄代码 |

把位置挂进 Finder 的三种方式，选 FSKit：

1. **FSKit**（选它）：macOS 15.4 起的用户态文件系统扩展，macOS 26 新增 `FSGenericURLResource`，专门给网络/远程这类「只有一个 URL」的文件系统用。挂出来是真正的卷，所有 App（Finder、终端、rsync）都能用。SideMount 就是这么做的。代价：用户首次要到「系统设置 › 通用 › 登录项与扩展 › 文件系统扩展」里打开开关；开发者论坛有人反映 CPU 占用比 macFUSE 高；扩展必须沙盒运行。
2. File Provider：为云盘同步设计，带占位文件和本地缓存，语义是「同步」不是「挂载」，对 USB 设备不合适，弃用。
3. 本地 WebDAV 服务 + 系统 `mount_webdav`（DroidMount / adbdav 的做法）：不需要任何特殊权限，但 macOS 的 WebDAV 客户端慢、会产生大量 `._` 文件、断线体验差。只作为 FSKit 走不通时的备选思路记录，不实现。

SMB 不走 FSKit，直接让系统挂载。

## 3. 总体架构

### 3.1 最低系统与工程

- 最低 macOS 26.0（`FSGenericURLResource` 从 26 开始才有）。
- Swift 6（严格并发检查），SwiftUI 为主，必要处用 AppKit。
- 工程用 XcodeGen 生成：仓库里提交 `project.yml`，`.xcodeproj` 不入库（App 扩展必须用 Xcode 工程构建，SwiftPM 做不了；`project.yml` 比 pbxproj 好审、好改）。
- 签名分两个阶段（用户先开发、开发完再申请付费账号）：
  - **阶段一（免费，M0–M6）**：主 App 和开发工具用 ad‑hoc 签名（或免费 Apple ID 的「Apple Development」证书）在本机运行，不建 FSKit 扩展、不用 App Group、不用钥匙串共享访问组。此阶段 Windows SMB 已能完整使用；安卓、GR、网盘通过开发工具 `diskit-dev`（见 §3.2）和主 App 的连接测试验收。
  - **阶段二（付费，M7）**：FSKit 扩展的 `com.apple.developer.fskit.fsmodule` 是受限权限，必须由付费团队生成的描述文件授权，ad‑hoc 或免费账号编出来的扩展系统不会加载（Apple 技术支持在开发者论坛明确说过，ntfstool、xntfs、Cryptomator 等开源项目也都这么写）。付费账号到手后再加扩展、App Group 和钥匙串共享访问组。
  - 阶段一代码不得写任何依赖 Team ID 的东西（App Group 路径、访问组名都通过 §7 的存储抽象切换），保证阶段二只是新增，不用重写。

### 3.2 进程与模块

```
Diskit.app                        主 App（菜单栏 UI、连接管理、设备发现、OAuth/扫码登录、发起挂载/推出）
 └─ Contents/Extensions/
    └─ DiskitFS.appex             FSKit 扩展（真正处理 Finder 的文件读写，按 URL scheme 分发到各 Provider）

Packages/
 ├─ Core            共享：连接模型、配置存储、钥匙串、日志、通用错误、Provider 协议
 ├─ ADB             ADB 协议（消息编解码、认证、sync 服务、shell 服务、USB/TCP/TLS 传输、无线配对）
 ├─ AliyunDrive     阿里云盘开放平台客户端
 ├─ Quark           夸克网页接口客户端
 ├─ RicohGR         GR IV（USB 走 ImageCaptureCore；Wi‑Fi 验证代码）
 └─ DevTool         开发工具 diskit-dev（命令行，见下）

（DiskitFS.appex 在 M7 才加；M0–M6 没有扩展。）
```

- **开发工具 `diskit-dev`**：SwiftPM 命令行程序，直接调用各 Provider，不经过 FSKit，用于阶段一验收和以后排查问题。子命令：`devices`（列出发现的安卓 / GR）、`pair <host:port> <配对码>`、`ls <连接ID> <路径>`、`stat`、`get <远端> <本地>`、`put <本地> <远端>`、`mkdir`、`rm [-r]`、`mv`、`df`、`cat --range <起>-<止>`（验证按范围读）。连接 ID 和密钥从主 App 保存的配置与钥匙串读取，所以网盘先在主 App 里登录，再用工具测。传输时打印进度和平均速度。
- 主 App 和扩展都链接 Core 和各 Provider 包；**设备连接由扩展持有**：挂载期间只有扩展打开手机的 ADB 接口，主 App 只做发现（监听 USB 插拔、mDNS），不打开接口，避免两个进程抢设备。
- 主 App 和扩展之间不做 XPC：配置走 App Group 共享容器里的 JSON，密钥走共享钥匙串访问组。主 App 通过挂载 URL 把「连接 ID」传给扩展，扩展自己读配置和密钥。
- 挂载状态由主 App 通过系统挂载表（`getmntinfo` / `NSWorkspace` 卷挂载通知）判断，不依赖扩展回报。

### 3.3 Provider 协议（Core）

所有远端位置实现同一个协议，FSKit 层只认这个协议：

```swift
protocol RemoteFileProvider: Sendable {
    var capabilities: ProviderCapabilities { get }      // 是否可写、可改名、可移动、是否支持按范围读取
    func connect() async throws
    func disconnect() async
    func spaceInfo() async throws -> SpaceInfo           // 总容量 / 已用
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func read(_ path: RemotePath, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error>
    func write(_ path: RemotePath, from localFile: URL) async throws   // 整文件上传
    func makeDirectory(_ path: RemotePath) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func move(_ from: RemotePath, to: RemotePath) async throws         // 改名也走这里
}
```

- 网盘是按 ID 寻址的，Provider 内部维护「路径 → 文件 ID」缓存，对外只暴露路径。
- 错误统一映射成 POSIX 错误（`ENOENT`、`EACCES`、`ENOSPC`、`EIO`、`ETIMEDOUT`……），FSKit 层直接返回给系统。

### 3.4 FSKit 层通用规则

- 一个扩展，`FSSupportedSchemes` 覆盖已有的 24 种非系统类型，共 23 个 scheme；安卓 USB 与 Wi-Fi 共用 `diskit-adb`，GR 本轮保留原行为。URL 形如 `diskit-adb://<连接ID>`，具体映射以 Core 的 `ConnectionKind.fileSystemScheme` 为准。名称保持不超过 15 个 ASCII 字节：本机正式接入时，过长的 scheme 使整个扩展不被系统发现；此约束未见 Apple 公开说明。
- 用 `FSUnaryFileSystem` + `FSGenericURLResource`，一个挂载一个卷。
- 挂载方式、挂载点位置（是否能在 `/Volumes` 以外且不需要 root）、是否出现在 Finder 侧栏「位置」里：以 M7 验证结论为准。
- **目录缓存**：目录列表按路径缓存，设备 5 秒、网盘 30 秒过期；本卷内的写/删/改名操作立即让相关目录缓存失效。
- **读**：Provider 支持按范围读（网盘的下载链接支持 HTTP Range）就直接按范围读；不支持（ADB sync 协议只能整文件拉取）时，第一次非顺序读把整个文件拉到本地缓存目录，后续从缓存读。缓存目录在扩展容器内，总大小上限默认 5 GB，按最近使用淘汰。
- **写**：创建或打开写入时写到本地临时文件，关闭（或 fsync）时整文件上传；上传失败把错误返回给关闭操作，并在 `docs` 里约定的日志里记一条。不支持原地随机改写远端文件，改写等同于重新上传。
- **macOS 元数据文件**：`.DS_Store`、`._*`、`.Spotlight-V100`、`.fseventsd`、`.Trashes` 不写到远端，存在本地覆盖层（扩展容器里按连接 ID 分目录），对 Finder 表现为存在。具体实现方式以 M7 验证结论为准。
- **只读能力**：Provider 声明不可写的操作，FSKit 层直接返回 `EROFS` / `EACCES`，不去调用远端。
- **断线**：远端断开（拔线、网络断）时，进行中的操作返回 `EIO`；主 App 检测到设备消失后主动推出卷。

### 3.5 备选方案（只在 M7 否定 FSKit 时启用）

如果 M7 第一步验证证明 FSKit 无法使用，或性能不可接受，就改为：主 App 内提供一个文件浏览窗口（列表 + 面包屑 + 拖入上传 / 拖出下载 + 右键删除改名 + 底部传输队列），Provider 直接在主 App 进程里运行。此时 M7 的「Finder 中」验收改为「浏览窗口中」。是否切换由用户拍板，Codex 不自行切换。

风险说明：FSKit 放到最后，意味着它若走不通要到最后才知道。已知 SideMount、ntfstool（已上架 Mac App Store）、Cryptomator 都在用 FSKit 挂载，判断风险可接受；Provider 与 FSKit 层之间只隔着 §3.3 的协议，即使切到备选方案，M2–M6 的代码全部复用。

## 4. 功能清单

### 4.1 菜单栏面板

- F1 菜单栏图标：未挂载任何位置时为普通图标；有已挂载位置时图标带小圆点。
- F2 面板顶部：App 名 + 右侧状态胶囊（例如「2 个已挂载」）。
- F3（M7 起）扩展未启用横幅：检测到 FSKit 扩展未启用时，在顶部显示黄色横幅「启用文件系统扩展」，点击打开系统设置对应页面（检测与跳转 API 以 FSKit 官方文档为准）。
- F4 「已发现」分组：自动发现但还没保存的设备——插着的安卓手机（USB）、局域网里开着无线调试的安卓手机、Bonjour 广播的 SMB 主机、USB 连着的 GR IV。每行一个「添加」按钮，点了进入添加流程并预填信息。
- F5 「我的位置」分组：已保存的连接，每行：类型图标、名称、副标题（状态：未连接 / 连接中 / 已挂载 · 可用 xx GB / 出错原因）、右侧主按钮（挂载 / 推出 / 重试）。
- F6 行右键菜单：在 Finder 中打开（已挂载时）、编辑、重新登录（网盘）、删除连接。删除连接前若已挂载先推出；删除连接同时删除对应钥匙串条目和本地缓存。
- F7 拖动排序。
- F8 底部栏：左侧版本号；右侧设置、退出，不放帮助入口。退出前推出全部本 App 挂载的卷（SMB 卷除外，SMB 由系统托管，退出不影响）。
- F9 空状态：没有任何连接时显示插图 + 「添加位置」按钮。
- F10 「添加位置」按钮：在列表底部常驻。

### 4.2 添加 / 编辑连接（独立窗口，不在面板里做长表单）

- F11 第一步选类型：安卓手机、Windows 共享、理光 GR IV、阿里云盘、夸克网盘。
- F12 每种类型的表单见 §6。通用字段：显示名称、图标颜色、「打开 App 时自动挂载」开关、「挂载后自动在 Finder 打开」开关。
- F13 保存前做一次连接测试，成功才允许保存；失败显示具体原因（未授权、密码错、超时、扩展未启用……）。

### 4.3 挂载后的文件操作能力

| 操作 | 安卓 ADB | Windows SMB | GR IV USB | 阿里云盘 | 夸克 |
| --- | --- | --- | --- | --- | --- |
| 浏览 / 读取 / 预览 | ✓ | ✓（系统） | ✓ | ✓ | ✓ |
| 拷入（上传） | ✓ | ✓ | ✗ 只读 | ✓ | ✓ |
| 新建文件夹 | ✓ | ✓ | ✗ | ✓ | ✓ |
| 删除 | ✓ | ✓ | ✓（相机支持时） | ✓（进回收站） | ✓（进回收站） |
| 改名 / 移动 | ✓ | ✓ | ✗ | ✓ | ✓ |
| 显示容量 | ✓ | ✓ | ✓ | ✓ | ✓ |

### 4.4 设置窗口

- F14 开机自动启动（`SMAppService.mainApp`）。
- F15（M7 起）文件系统扩展状态 + 「打开系统设置」按钮。
- F16 缓存：显示当前缓存占用、上限（默认 5 GB，可改）、「清空缓存」按钮（会先提示需要推出全部卷）。
- F17 ADB：显示本机 ADB 密钥指纹；「重新生成密钥」（提示手机需重新授权）；检测到本机有其它 adb server 占用设备时的提示方式。
- F18 日志：「在 Finder 中显示日志」按钮。日志用 `os.Logger`（subsystem 为 Bundle ID），另外把最近 7 天错误级日志写到数据目录（§7）里的文本文件，方便用户导出。

### 4.5 通知

- F19 只在这几种情况发系统通知：挂载失败、设备意外断开导致卷被推出、网盘登录过期需要重新登录。其余不打扰。

## 5. UI 规格

- 面板：`MenuBarExtra(.window)`，宽 380pt，高度随内容，最大 560pt 超出滚动。跟随系统深浅色，默认风格参考截图里的 SideMount：大标题、圆角 10–12pt 的行卡片、分组标题小号灰字、底部栏与内容之间一条分隔线。
- 行高 52pt；类型图标 28pt 圆角方块；主按钮用 `.bordered` 小号控件。
- 只用系统控件与 SF Symbols，不引入第三方 UI 库。
- 文案中文为主，用 String Catalog（`Localizable.xcstrings`）管理，同时提供英文。
- 面板关闭时停止一切仅为显示服务的轮询（容量刷新等）；容量在面板打开时刷新一次，之后 30 秒一次。

## 6. 各位置类型实现细节

### 6.1 安卓 · USB（ADB）

**发现**：IOKit 匹配通知监听 USB 接口 `bInterfaceClass=0xFF, bInterfaceSubClass=0x42, bInterfaceProtocol=0x01`（ADB 接口）。读取设备序列号、厂商、型号显示在「已发现」里。主 App 只读描述信息，不打开接口。

**协议**（参考 AOSP `packages/modules/adb` 源码与 `protocol.txt`、`SYNC.TXT`，Apache‑2.0）：

- 消息头 24 字节小端：`command, arg0, arg1, data_length, data_crc32, magic(command ^ 0xFFFFFFFF)`；命令 `CNXN / AUTH / OPEN / OKAY / WRTE / CLSE / STLS`。
- 连接：发 `CNXN`（version `0x01000001`，maxdata 1 MB，banner `host::features=...`），收到 `AUTH TOKEN` 后用本机 RSA 私钥签名回 `AUTH SIGNATURE`；手机未信任时发 `AUTH RSAPUBLICKEY`，手机弹「允许 USB 调试吗」，用户点允许后收到 `CNXN`。
- 本机密钥：RSA 2048，首次运行生成，存共享钥匙串。公钥按 Android 的格式编码（参考 AOSP `rsa_2048_key` / `android_pubkey`），附 `@<主机名>` 后缀。
- 解析手机 `CNXN` banner 里的 features，有 `ls_v2`、`stat_v2`、`sendrecv_v2` 时用 v2 命令（`LIS2 / STA2 / RCV2 / SND2`），否则退回 v1（v1 的大小字段是 32 位，超过 4 GB 的文件要提示不支持）。
- 文件操作：`sync:` 服务做列目录、stat、拉取、推送；删除、移动、建目录用 `shell,v2,raw:` 执行 `rm -rf`、`mv`、`mkdir -p`，参数必须做 shell 单引号转义，并检查退出码。
- 按范围读的优化（可选，M2 之后做）：用 `exec:dd if=<path> bs=65536 skip=<n> count=<m>` 读片段，供 Quick Look 预览大视频时不用拉整个文件。
- 根目录展示：卷根目录直接映射到 `/sdcard`；同时显示一个「SD 卡」子目录（检测到 `/storage/XXXX-XXXX` 时）。

**传输层**：IOUSBHost（`IOUSBHostInterface` + bulk in/out 管道）。阶段一主 App 与 `diskit-dev` 不开沙盒，无需额外权限；M7 的扩展是沙盒进程，需要 `com.apple.security.device.usb` 权限。

**冲突处理**：打开接口失败（被占用）时，返回明确错误「手机正被其它 adb 程序占用，请先执行 `adb kill-server`」，面板该行显示同样提示。

**表单**：只需选设备 + 名称。首次连接面板显示「请在手机上点允许 USB 调试」并等待，最长 60 秒。

### 6.2 安卓 · Wi‑Fi（无线调试，Android 11+）

- 发现：`NWBrowser` 浏览 `_adb-tls-pairing._tcp`（配对）与 `_adb-tls-connect._tcp`（连接）。`Info.plist` 声明 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`。
- 配对（每台手机一次）：用户在手机「无线调试 › 使用配对码配对设备」，在 App 里输入 6 位码。流程按 AOSP `pairing_auth` / `pairing_connection`：TLS 1.3 连接配对端口 → 用 TLS exporter 导出密钥材料（Network.framework 的 `sec_protocol_metadata_create_secret`）拼在配对码后作为口令 → SPAKE2 交换 → 用派生密钥 AES‑128‑GCM 加密交换 PeerInfo（本机 RSA 公钥）。
- SPAKE2 使用 BoringSSL 的实现：把 BoringSSL 以 C target 方式 vendor 进 ADB 包（保留其许可证文件），**不手写任何密码学代码**。经用户批准，BoringSSL 也用于 ADB Android 公钥编码所需的大整数运算；RSA 密钥生成和签名仍使用 Security。
- 连接：TCP 连接 `_adb-tls-connect` 端口 → `CNXN` → 收到 `STLS` → 升级 TLS 1.3，用本机 RSA 密钥自签证书做客户端证书（Network.framework `sec_identity`）→ 后续与 USB 完全相同的 ADB 消息流。
- 手机端口会变：每次挂载按保存的设备标识（配对时记录的 GUID）重新用 mDNS 找当前端口。
- 同一台手机同时有 USB 和 Wi‑Fi 时，优先 USB（与 SideMount 一致）。

### 6.3 Windows 电脑（SMB）

- 发现：`NWBrowser` 浏览 `_smb._tcp`；Windows 默认不广播，表单里必须支持手动填 IP 或主机名。
- 表单：主机、用户名、密码、共享名。「列出共享」按钮调用 `/usr/bin/smbutil view //user@host`（密码通过环境或交互方式传入，不出现在命令行参数里；以实际可行方式为准）解析共享列表供选择。
- 保存前连接测试：用 `NetFSMountURLAsync` 和填写的用户名、密码建立新会话，在独立临时路径挂载所选共享，验证后推出；不改动已有挂载。列出共享仍使用 `smbutil`，其结果不代替密码验证。
- 挂载：`NetFSMountURLAsync`，URL `smb://host/share`，用户名密码从钥匙串取，挂载到系统默认位置（`/Volumes`）。推出：`NSWorkspace.unmountAndEjectDevice(at:)`。
- 添加窗口的准备说明写明：Windows 需开启「文件和打印机共享」；微软账户登录的电脑用户名填邮箱、密码填微软账户密码而不是 PIN。

### 6.4 理光 GR IV

**USB（本期实现）**：

- 发现与访问：`ImageCaptureCore`（`ICDeviceBrowser` → `ICCameraDevice`），读取文件列表、下载原图（JPG / DNG）、删除（`requestDeleteFiles`，相机拒绝时返回 `EACCES`）。
- 卷结构：根目录按相机存储分成「内置存储」「microSD」，下面保持相机原始目录（`DCIM/100RICOH/...`）。只读 + 删除。
- 是否能在 FSKit 扩展进程里使用 ImageCaptureCore，以 M7 验证结论为准。不能的话，GR 改为主 App 内的「导入新照片」功能：选择目标文件夹，只下载目标文件夹里还没有的文件（按文件名 + 大小判断），下载完在 Finder 打开目标文件夹；面板该行主按钮变为「导入」。

**Wi‑Fi（只做技术验证，M8，不承诺）**：

- 已知：GR II/III 连相机热点后有 HTTP 接口：`GET http://192.168.0.1/v1/props`（型号电量）、`GET /v1/photos`（全部目录与文件）、`GET /v1/photos/{dir}/{file}`（原图）。GR WORLD 连上 GR IV 后会写 `http://192.168.0.1/v1/params/device`，说明 GR IV 很可能也是这一套。
- 未知：GR IV 机身菜单没有 Wi‑Fi 开关，必须由蓝牙（BLE）命令唤起，命令格式和 Wi‑Fi 密码获取方式都没有公开资料。验证方法：安卓开「蓝牙 HCI 信息收集日志」后用 GR WORLD 传一次图，抓日志分析。
- Mac 加入相机热点用 CoreWLAN，会断开当前外网，界面上要提示。
- 验证不通就停，写结论，不要在主线上留半成品。

### 6.5 阿里云盘

- 官方开放平台（`https://openapi.alipan.com`），OAuth2 授权码模式：主 App 用 `ASWebAuthenticationSession` 打开授权页，回调用自定义 URL scheme，拿 `access_token` + `refresh_token` 存钥匙串，过期前自动刷新；刷新失败标记「需重新登录」并发通知。
- 需要的开发者 `client_id` / `client_secret` 写在本地不入库的配置文件里（`Config/Secrets.xcconfig`，提交 `Secrets.example.xcconfig`）。
- 用到的接口（具体路径、参数以官方文档为准）：用户与空间信息、文件列表（分页，`marker` 翻到底）、文件详情、获取下载链接（有效期短，过期重新取；支持 Range）、创建文件（分片上传：create → 逐片 PUT 到 `upload_url` → complete；分片上传链接过期时重新获取）、新建文件夹、重命名 / 移动、放入回收站。
- 删除一律放入回收站，不做彻底删除。
- 同名冲突：经用户批准，替换时先完成新文件上传，再把旧文件移入回收站；上传失败保留旧文件，回收失败明确报错并保留两份。若原目录已存在多份同名文件则报错，不猜选目标。这不是原子替换，file_id 会改变（官方开放平台不支持原位覆盖）。
- 遵守官方频率限制：并发请求上限 4，遇到限流按响应头或文档建议退避。

### 6.6 夸克网盘（实验性）

- 登录：主 App 内 `WKWebView` 打开夸克网页版登录页（扫码），登录成功后从 `WKHTTPCookieStore` 读取 Cookie（至少包含 `__puus`、`__pus`，具体以实测为准），存钥匙串。不提供手动粘贴 Cookie 以外的其它登录方式；手动粘贴作为兜底入口。
- 接口：参考 OpenList quark 驱动的行为（列目录、下载、预上传 → 哈希 → OSS 分片上传 → 完成、新建、改名、移动、删除）。**OpenList 是 AGPL‑3.0，只能参考接口行为，禁止复制代码。**
- 请求统一带浏览器 UA、Referer 与 Cookie；响应若刷新了 Cookie 要回写钥匙串。
- Cookie 失效（接口返回未登录）：标记「需重新登录」，发通知，已挂载卷后续操作返回 `EACCES`。
- 在添加窗口明确标注「非官方接口，可能随时失效」。
- 经用户批准，同名上传明确报错，不自动改名、不覆盖或回收旧文件。

## 7. 数据模型与存储

- 配置文件：数据目录下的 `connections.json`（位置见下方存储表），结构：

```json
{
  "version": 1,
  "connections": [
    {
      "id": "UUID",
      "kind": "androidUSB | androidWiFi | smb | ricohGR | aliyunDrive | quark",
      "name": "我的 Pixel",
      "color": "blue",
      "autoMount": false,
      "openInFinderAfterMount": true,
      "order": 0,
      "params": { "serial": "..." }
    }
  ]
}
```

- `params` 按类型不同：安卓 USB 存序列号；安卓 Wi‑Fi 存配对 GUID 与名称；SMB 存主机、用户名、共享名；GR 存序列号；网盘存账号昵称与用户 ID。
- 密码、令牌、Cookie、ADB 私钥一律只存钥匙串，键为 `<连接ID>.<用途>`；ADB 私钥键为 `adb.private-key`。
- 配置文件写入用原子写；`version` 字段用于以后迁移。
- **存储位置通过 Core 里的 `StorageLocation`（数据目录）和 `SecretStore`（钥匙串）两个抽象访问，业务代码不直接拼路径、不直接调 `SecItem*`**：

| | 阶段一（M0–M6，无付费账号） | 阶段二（M7 起） |
| --- | --- | --- |
| 数据目录 | `~/Library/Application Support/Diskit/` | App Group 容器 `<TeamID>.com.seaony.Diskit` |
| 钥匙串 | 传统登录钥匙串，service 前缀 `com.seaony.Diskit`；**禁止**设置 `kSecUseDataProtectionKeychain=true`（没有描述文件时会报 `errSecMissingEntitlement -34018`） | 共享访问组 `<TeamID>.com.seaony.Diskit.shared` |
| 缓存与元数据覆盖层 | `~/Library/Caches/Diskit/<连接ID>/` | 扩展容器内 `Caches/<连接ID>/` |

- 阶段一签名优先用免费 Apple ID 的「Apple Development」证书：签名身份稳定，重新编译后钥匙串不会反复弹「允许访问」；Xcode 没登录 Apple ID 时退回 ad‑hoc，代价是每次重新编译后首次读钥匙串要点一次允许。`diskit-dev` 读主 App 存的条目时也会弹一次，点「始终允许」即可。
- 进入阶段二时做一次性迁移：主 App 启动发现旧位置有数据、新位置没有，就把配置文件搬到 App Group 容器、把钥匙串条目复制到共享访问组，确认写入成功后再删旧条目；迁移失败保留旧数据并提示，不丢数据。

## 8. 里程碑与验收标准

每个里程碑结束时：`make release` 构建通过、`make test` 全部单元测试通过、按本节逐条手动验收，并在 `docs/ACCEPTANCE.md` 里记录每条的实际结果（通过 / 不通过 + 现象 + 实测数据）。不允许只写「已完成」。

M0–M6 不需要付费开发者账号；M7 需要。M0–M6 里「挂载 / 在 Finder 中」的验收只针对 SMB，其余类型用 `diskit-dev` 和主 App 的连接测试验收，Finder 相关验收统一放到 M7。

阶段一面板行为：非 SMB 连接的行主按钮显示为「测试连接」，副标题显示连接结果和容量；「挂载」按钮在 M7 才出现。F3 横幅、F15 扩展状态也在 M7 才做。

### M0 工程骨架

交付：`project.yml`（XcodeGen）、主 App target、`Packages/` 下各包的空壳与 `diskit-dev` 可执行目标、`Makefile`（`make gen` / `make build` / `make release` / `make test` / `make dev-tool`）、`docs/ACCEPTANCE.md` 模板、`README.md`（构建步骤与签名说明）。

验收：

1. 新克隆的目录里依次执行 `make gen && make test && make release` 全部成功，不需要手动打开 Xcode 改设置。
2. Release 产物 `codesign --verify --deep --strict --verbose=2` 通过；`Info.plist` 的 `LSMinimumSystemVersion` 为 `26.0`、`LSUIElement` 为 `true`。
3. `diskit-dev --help` 列出 §3.2 的全部子命令（M0 阶段子命令可以只打印「未实现」）。
4. `StorageLocation` / `SecretStore` 有单元测试：写入、读取、删除、覆盖。

### M1 菜单栏骨架 + 连接管理 + Windows SMB

验收：

1. 启动后只有菜单栏图标，没有 Dock 图标；点击弹出面板，样式符合 §5。
2. 无连接时显示空状态；能添加、编辑、删除、拖动排序连接；退出重开后配置保持。
3. SMB：手动填 Windows 电脑 IP、账号、密码，「列出共享」能列出共享名；挂载后 Finder 出现该共享；能拷入、拷出、删除、改名、新建文件夹；推出后卷消失。
4. 局域网里有 Bonjour 广播 SMB 的机器（例如另一台 Mac）时，「已发现」里能看到它。
5. 密码错误时，保存前的连接测试给出「用户名或密码错误」而不是通用错误。
6. 删除连接后，钥匙串里对应条目被删掉（用 `security find-generic-password -s ...` 验证查不到）。
7. 开机自启开关有效（注销重新登录后验证）。
8. 「打开 App 时自动挂载」开启的 SMB 连接，重启 App 后自动挂载。

### M2 安卓 USB（ADB 协议）

验收：

1. 插入开了 USB 调试的安卓手机，面板「已发现」里出现手机型号，拔出后消失；`diskit-dev devices` 同样能列出。
2. 首次连接：手机弹出授权框，点允许后连接成功；第二次连接不再弹框。
3. 用 `diskit-dev`：`ls /sdcard/DCIM`；`put` 一个文件夹（含子目录、中文文件名、空格、emoji 文件名）；`mkdir`；`mv` 改名；`rm -r`；每步之后用官方 `adb shell ls`（先退出 diskit-dev）确认手机上的结果一致。
4. `get` / `put` 一个大于 4 GB 的文件（手机支持 v2 时），两端 SHA‑256 一致。
5. 速度：USB 3 线 + 支持 USB 3 的手机，`get` 1 GB 文件平均 ≥ 20 MB/s；记录实测值和设备型号，达不到要写出瓶颈分析。
6. 传输中拔线：命令报错退出，不崩溃、不挂死；面板该行变为「未连接」；重新插入后能再次连接。
7. 本机有其它 `adb server` 占用手机时，`diskit-dev` 与面板都显示 §6.1 的占用提示。
8. 单元测试：消息编解码（用 AOSP 真实字节做固定样例）、CRC/magic 校验、RSA 公钥编码（与官方 `adb` 生成的 `adbkey.pub` 格式逐字节一致）、sync v1/v2 帧解析、shell 参数转义。

### M3 安卓 Wi‑Fi

验收：

1. 手机打开无线调试后，首次「已发现」显示「<ADB 服务名>（Wi‑Fi）」；保存后使用用户填写的名称（经用户批准，未配对时不保证取得手机名）。
2. 在添加窗口输入配对码完成配对；手机「已配对的设备」列表里出现本机名称。
3. 走 Wi‑Fi 时 M2 第 3、4 条全部通过。
4. 手机关掉再打开无线调试（端口变化）后仍能连上，无需重新配对。
5. USB 和 Wi‑Fi 同时可用时走 USB（日志可证）。
6. 配对码输错时提示「配对码错误」，可重试。

### M4 理光 GR IV（USB）

验收（需要真机；没有相机就标「未测」并说明）：

1. USB 连接相机后「已发现」里出现 GR IV。
2. `diskit-dev ls` 能看到内置存储和 microSD 的目录与文件；`get` 拷出 JPG 和 DNG，大小与相机端一致；`rm` 删除一张照片后相机回放里也消失（相机不允许删除时返回明确错误）。
3. 写入类命令（`put` / `mkdir` / `mv`）直接返回只读错误，不访问相机。

### M5 阿里云盘

前提：用户已拿到开放平台 `client_id`。拿到之前可以先写代码和单元测试，真机验收等拿到后补。

验收：

1. 添加时弹出官方授权页，授权完成后自动回到 App，显示账号昵称和容量。
2. 用 `diskit-dev`：`ls` 超过 100 个文件的目录（翻页完整，条数与网页版一致）；`cat --range` 读视频文件中间一段（验证 Range）；`put` 一个 > 1 GB 文件（验证分片上传），网页版能看到且大小一致；`mkdir`、`mv`、`rm`（网页版回收站可见）。
3. 手动把钥匙串里的 access_token 改成无效值后再操作，能用 refresh_token 自动恢复。
4. 在网页版取消授权后，App 发出「需重新登录」通知，面板该行显示「重新登录」。
5. 单元测试：分页拼接、路径 ↔ ID 缓存失效、分片切分（边界：0 字节、正好整片、最后一片不足）。

### M6 夸克网盘（实验性）

验收：

1. 扫码登录成功，显示账号与容量。
2. 用 `diskit-dev`：`ls`、`cat --range`、`put`（> 100 MB）、`get`、`mkdir`、`mv`、`rm` 全部可用，网页版结果一致。
3. 清空钥匙串里的 Cookie 后操作，App 发出「需重新登录」通知，不崩溃。

### M7 FSKit 挂载进 Finder（需要付费开发者账号）

前提：用户已加入 Apple Developer Program，在开发者后台给 App ID 打开「FSKit File System Module」能力，并提供 Team ID。

**第一步：验证**（交付 `docs/SPIKE.md`，逐条写结论和证据）

1. 最小 FSKit 扩展（`FSUnaryFileSystem` + `FSGenericURLResource`，内存假数据 3 个文件 1 个目录）能被系统识别，在系统设置里能打开开关。
2. 主 App 能在**不需要管理员密码**的前提下挂载并推出；写清楚用的 API / 命令、挂载点位置、是否出现在 Finder 侧栏「位置」、卷名称与图标能否自定义。
3. 扩展能读到主 App 写进 App Group 的配置和共享访问组里的钥匙串条目；§7 的一次性迁移跑通。
4. 扩展进程内能通过 IOUSBHost 打开真实安卓手机的 ADB 接口并完成握手。
5. 扩展进程内能否用 ImageCaptureCore 看到 GR IV（没有相机写「未测」）。不能的话 GR 按 §6.4 改为主 App 的「导入新照片」。
6. Finder 往卷里拷文件时产生哪些 `._*` / `.DS_Store` 操作，§3.4 的覆盖层方案是否可行。
7. 性能基线：假数据卷读 1 GB 内存文件的吞吐和扩展进程 CPU 占用。

任一项不通过：停下，写清楚原因和备选，等用户决定，不自行切到 §3.5 备选方案。

**第二步：接入**（全部通过后）

1. 面板出现 F3 横幅、F15 扩展状态；非 SMB 行主按钮变为「挂载 / 推出」。扩展未启用时点挂载，提示并跳转系统设置。
2. 安卓（USB 与 Wi‑Fi 各测一遍）：在 Finder 中浏览 `DCIM`、Quick Look 预览照片和视频、拷入文件夹（含中文 / 空格 / emoji 文件名）、新建文件夹、改名、移动、删除，结果与手机一致；Finder 拷出 1 GB 文件的速度不低于 M2 用 `diskit-dev` 实测值的 70%（记录两个数）。
3. 拷贝中拔线：Finder 报错不卡死，卷被自动推出，App 不崩溃；重新插入后能再挂载。
4. 终端 `cp`、`rsync -a` 往安卓卷拷一个目录，结果正确。
5. GR IV：只读卷浏览、预览、拷出、删除可用；往卷里拷文件时 Finder 提示只读，不出现部分写入。（或「导入新照片」：第二次导入只下载新增文件。）
6. 阿里云盘、夸克：Finder 浏览、预览视频可拖动进度、拷入大文件、新建、改名、移动、删除，网页版结果一致。
7. 远端卷里不出现 `.DS_Store`、`._*` 文件（用 `diskit-dev ls -a` 或网页版确认）。
8. 「打开 App 时自动挂载」对所有类型生效；退出 App 时推出本 App 挂的全部卷（SMB 除外）。
9. `pluginkit -m -v` 能看到扩展；Release 包签名校验通过。

### M8 GR IV Wi‑Fi 技术验证（可选，用户确认后再做）

交付 `docs/SPIKE-GR-WIFI.md`：BLE 服务/特征 UUID、唤起 Wi‑Fi 的命令、取得 SSID 与密码的方式、`/v1/photos` 在 GR IV 上是否可用。全部打通后再由用户决定是否做成功能。

## 9. 测试与验证方式

- 单元测试：Swift Testing，覆盖各协议编解码与纯逻辑；网络与 USB 通过协议抽象注入假实现，不依赖真机。
- 集成验证：真机手动验收，按 §8 写进 `docs/ACCEPTANCE.md`。
- **不写 UI 自动化测试、快照测试**；UI 由用户手动验收。
- 统一入口：`make gen`、`make build`、`make release`、`make test`、`make dev-tool`（Makefile 里调用 `xcodegen`、`xcodebuild`、`swift build`）。
- Release 产物签名校验：`codesign --verify --deep --strict --verbose=2`；M7 起确认扩展被正确嵌入（`pluginkit -m -v` 能看到）。

## 10. 工程约束（实现者必须遵守）

- 优先用系统框架：FSKit、IOUSBHost、ImageCaptureCore、NetFS、Network.framework、CoreWLAN、CoreBluetooth、AuthenticationServices、WebKit、Security。第三方依赖只允许 BoringSSL（SPAKE2、ADB Android 公钥编码）和构建工具 XcodeGen，新增任何依赖先问。
- 不调用外部 `adb` 可执行文件，不要求用户装 Android Platform‑Tools（验收时用官方 adb 对照结果除外）。
- 不手写密码学原语（RSA 签名用 Security 框架，TLS 用 Network.framework，SPAKE2 用 BoringSSL）。
- 参考开源代码时注意许可证：AOSP（Apache‑2.0）可参考并注明出处；OpenList（AGPL‑3.0）只能看行为不能复制。
- 阶段一不写任何依赖 Team ID 的代码，路径与钥匙串一律走 §7 的抽象。
- 日志和「复制详细信息」原样记录错误的完整原因（每一层的类型、错误域、错误码、说明），不脱敏：数据都在用户自己的电脑上。
- 所有远端调用有超时（设备 15 秒，网盘 30 秒，大文件传输按无进展 60 秒判超时）。
- Bundle ID：主 App `com.seaony.Diskit`，扩展 `com.seaony.Diskit.FS`，开发工具 `com.seaony.Diskit.dev`；OAuth 回调 `diskit://`，FSKit 使用单独的 `diskit-` 前缀 scheme。百度、腾讯、B2、R2、Google、移动、迅雷、天翼分别用 `diskit-baidu`、`diskit-cos`、`diskit-b2`、`diskit-r2`、`diskit-google`、`diskit-mobile`、`diskit-thunder`、`diskit-tianyi`，其余见 `ConnectionKind.fileSystemScheme`。
- 代码注释用简短中文，说明做什么、为什么，不写废话。
- 每个里程碑一个或多个小提交，提交信息一句话中文，不写 AI 相关字样。

## 11. 已确认的决定与待办

已确认（2026-11-03）：

1. 名称 Diskit。
2. 先开发、后申请付费开发者账号：M0–M6 不依赖付费账号，FSKit 放在 M7。
3. 阿里云盘开放平台 `client_id` 由用户后续申请，先写代码；夸克按实验性做，接受非官方接口随时失效的风险。
4. GR IV 以 USB 为主，Wi‑Fi 只做技术验证（M8，可选）。

开发中需要用户提供：

1. M5 真机验收前：阿里云盘 `client_id` / `client_secret`，以及开放平台登记的回调地址。
2. M7 开始前：付费账号的 Team ID，并在开发者后台给 `com.seaony.Diskit.FS` 打开 FSKit 能力。

## 12. 参考资料

- SideMount：https://sidemount.app/ ，https://sidemount.app/blog/adb-vs-mtp
- FSKit：https://developer.apple.com/documentation/fskit ，`FSGenericURLResource`：https://developer.apple.com/documentation/fskit/fsgenericurlresource ，挂载讨论：https://developer.apple.com/forums/thread/799283
- FSKit 需要付费团队的说明：https://github.com/The-Alchemist/FSKitSample ，https://github.com/ntfstool/ntfstool ，https://github.com/cryptomator/fskit-nio-adapter
- DroidMount：https://github.com/Ludovienne974/DroidMount ；adbdav：https://github.com/olragon/adbdav
- mtp-mount（MTP 按需读取思路）：https://docs.rs/crate/mtp-mount/0.3.1
- libmtp（MTP 的事实标准实现，LGPL C；USB 收发细节和各设备已知问题以它为对照）：https://github.com/libmtp/libmtp
- AOSP adb：https://android.googlesource.com/platform/packages/modules/adb/
- GR III Wi‑Fi 接口：https://github.com/aspyct/grit ，https://github.com/sotashimozono/gr3sync
- GR WORLD 分析笔记：https://github.com/sky18Dragon/grCameraAnalysis
- GR IV 官方 FAQ：https://www.ricoh-imaging.co.jp/english/support/qa/gr-4/
- 阿里云盘开放平台（OpenList 驱动说明）：https://doc.oplist.org/guide/drivers/aliyundrive_open
- 阿里云盘第三方权益包报道：https://www.tjsky.net/news/927
- 夸克（OpenList 驱动说明）：https://doc.oplist.org/guide/drivers/quark
