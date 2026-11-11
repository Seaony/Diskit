# 验收记录

> 0.2说明：下列M0–B4及旧截图记录均是历史阶段证据，其“通过”、机器环境和执行顺序不代表当前0.2工作区。0.2本地最终结果统一见`OPTIMIZATION-REPORT.md`；真实设备/账号/真实菜单栏新增矩阵见本文末尾UA-02。没有执行的外部项目一律待用户验收。

日期：起始 2026-11-03，最后更新 2026-11-04。环境：macOS 26.5.2（25F84）、Xcode 26.6（17F113）、Swift 6.3.3、XcodeGen 2.46.0。
只记录实际运行的结果；界面与外部设备不由单元测试替代。

## M0 工程骨架

| 标准 | 结果 | 证据 |
| --- | --- | --- |
| 新克隆执行 make gen / make test / make release | 通过 | 新克隆 `/tmp/kayoi-m0-clone.Ki0yAJ` 执行 `make gen && make test && make release`，退出码 0；测试 2/2 通过，Release `BUILD SUCCEEDED`，签名校验通过 |
| Release 签名与 Info.plist | 通过 | `codesign --verify --deep --strict --verbose=2`：`valid on disk`、`satisfies its Designated Requirement`；PlistBuddy：LSMinimumSystemVersion=`26.0`、LSUIElement=`true` |
| kayoi-dev --help 全部子命令 | 通过 | devices、pair、ls、stat、get、put、mkdir、rm、mv、df、cat --range 均列出；M0 执行具体命令返回未实现与非零退出码 |
| StorageLocation / SecretStore 写读删覆盖 | 通过 | `make test`：`Test run with 2 tests in 0 suites passed`；配置使用临时目录，密钥使用真实登录钥匙串随机 service 并清理 |

签名身份为指定的 Apple Development 证书。App 为 arm64 + x86_64，开发工具为本机架构。未启用沙盒、App Group、共享钥匙串、FSKit 或 Developer ID。

## M1 菜单栏与 SMB

实现与自动检查通过；下列真实系统交互需用户验收，未冒充真机通过。

| 标准 | 结果 | 已有证据与待测内容 |
| --- | --- | --- |
| 1. 只有菜单栏图标，面板符合 §5 | 待用户验证 | Release 编译与签名通过；LSUIElement=true；实现 380pt、52pt 行和最大 560pt 面板。未启动或操作界面验收 |
| 2. 空状态、增删改、拖动排序、重启保持 | 待用户验证 | 假实现测试覆盖保存、编辑、排序和重新加载；实际拖动与窗口行为待测 |
| 3. 列共享、挂载、Finder 文件操作、推出 | 待用户验证 | SMB URL、共享列表解析测试通过；接入 smbutil / NetFSMountURLAsync / NSWorkspace。没有 Windows 账号，未进行网络或文件操作 |
| 4. Bonjour SMB 自动发现 | 待用户验证 | NWBrowser 浏览 `_smb._tcp`、NetService 解析地址，代码构建通过；未验证局域网广播 |
| 5. 错误密码明确提示且不能保存 | 待用户验证 | 假实现 authentication 拒绝保存测试通过；实际测试用所填密码新建 NetFS 会话并临时挂载。错误密码、系统已有认证、已有挂载三种真机情形待测 |
| 6. 删除后钥匙串对应条目消失 | 待用户验证 | 假实现验证先推出再删密钥/缓存/配置；真实登录钥匙串读写覆盖删除测试通过。App 连接删除后的 security 命令检查待测 |
| 7. 开机自启开关 | 待用户验证 | 接入 SMAppService.mainApp；未修改本机登录项，未注销重登 |
| 8. SMB 开启自动挂载后重启生效 | 待用户验证 | 假实现验证仅自动挂载开启项、跳过已经挂载的共享；真实重启待测 |

实际命令结果（2026-11-03）：

```text
$ make test
Test testingExistingConnectionDoesNotUnmountIt() passed after 0.008 seconds.
Test loginKeychainLifecycle() passed after 0.035 seconds.
Test run with 13 tests in 0 suites passed after 0.035 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

两次命令退出码均为 0。Xcode 仅报告未链接 AppIntents 的元数据提取提示，没有编译错误。未写 UI 自动化或快照测试。

用户批准的 §6.3 修订：

- 移除列共享命令的 `-A`，因为它只认证而不枚举共享。
- 保存前用 NetFS 和填写的密码进行独立连接测试，在数据目录 ConnectionTests 下的随机路径短暂挂载并推出；不改变已有挂载。
- `smbutil view -f` 通过独立终端输入密码，`-f` 避免直接复用现有会话，但其输出只用于列共享，不充当表单密码验证。

依据：[Apple view.c](https://github.com/apple-oss-distributions/smb/blob/main/smbutil/view.c)、[Apple server.c](https://github.com/apple-oss-distributions/smb/blob/main/lib/smbclient/server.c)、本机 NetFS.h。没有复制 Apple 源代码。

## M2 安卓 USB

实现与自动检查通过；没有连接安卓手机，不提供真机成功或速度结论。

| 标准 | 结果 | 证据 |
| --- | --- | --- |
| 1. 插拔发现与 devices | 待用户验证 | IOKit 匹配通知、描述属性读取及 CLI 已接入；本机 `build/bin/kayoi-dev devices` 退出码 0、输出 0 行，发现 0 台设备 |
| 2. 首次授权与再次连接 | 待用户验证 | 假传输验证 CNXN → AUTH 签名 → 公钥 → CNXN；真实手机授权框及重连待测 |
| 3. 列目录、递归上传、mkdir/mv/rm | 待用户验证 | v1/v2 目录、sync 上传下载、shell 单引号转义和失败退出码测试通过；CLI 已实现递归目录操作，未操作手机 |
| 4. 大于 4 GB 文件双向 SHA-256 | 待用户验证 | v2 解析 5,000,000,000 字节大小通过；v1 用 5 GB 稀疏测试文件验证拒绝上传；没有实际大文件传输或双端哈希结果 |
| 5. USB 3 下载 1 GB ≥20 MB/s | 待用户验证 | 无手机、线缆或实测数据，不估算速度；CLI 输出传输字节和平均 MB/s |
| 6. 拔线报错、面板断开、重新连接 | 待用户验证 | 假传输中断返回错误并关闭会话；Core 测试确认拔线状态不会被迟到的测试结果覆盖；真机拔线和重插待测 |
| 7. adb server 占用提示 | 待用户验证 | IOUSBHost exclusive-access/busy 错误映射到要求的提示；未启动 adb server、未制造真实接口占用 |
| 8. 消息/校验/公钥/sync/shell 单元测试 | 通过 | ADB 12 项测试通过。固定 OKAY 24 字节样例按 AOSP 线上格式手工列出（不是抓包）；官方 adb 公钥格式逐字节比对；Security 签名验签；分块读写与 shell 退出码均有假实现测试 |

命令输出：

```text
$ make test
Test run with 14 tests in 0 suites passed
Test run with 12 tests in 0 suites passed
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ build/bin/kayoi-dev devices
# stdout 为空，退出码 0；wc -l 为 0
```

共 26 项测试。官方对照工具是本机已有的 `/Users/seaony/Library/Android/sdk/platform-tools/adb`，版本 `37.0.1-15733141`；只用 `version` 和离线 `keygen`，没有启动服务或连接设备。

批准的依赖范围调整：BoringSSL 除 SPAKE2 外，也可用于 Android 公钥编码的 n0inv/rr 大整数运算。Security 仍负责 RSA 密钥生成及签名。来源、版本和许可证见 `THIRD_PARTY_NOTICES.md`。

协议说明：AOSP 历史文档的 data_crc32 字段实际使用字节累加和；0x01000001 起允许跳过，magic 仍校验。按实际 AOSP 实现处理，未使用 CRC32 算法。ADB Provider 不声明按范围读取能力；CLI 的 cat --range 顺序读取并截取输出，没有实现可选 dd 优化。

## M3 安卓 Wi-Fi

实现和自动检查通过；无安卓真机，以下均待用户验证。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 无线调试自动发现 | 待用户验证 | 原标准要求手机名，当前只能显示服务名；用户已批准修订为首次显示 ADB 服务名，保存后使用自定义名称。实际局域网发现仍待真机验证。 |
| 2. 配对码配对、手机显示本机 | 待用户验证 | SPAKE2、TLS exporter、HKDF、AES-GCM 和 PeerInfo 假实现互通通过；本机身份由 Security 创建，证书签名由系统信任检查验证通过；未与手机 TLS 互通 |
| 3. Wi-Fi 文件操作及 >4 GB 哈希 | 待用户验证 | 复用 M2 同一 Provider/sync/shell；Network.framework TCP + STLS 动态插入 TLS 1.3 编译通过，无实际传输数据 |
| 4. 端口变化后无需重新配对 | 待用户验证 | 测试用相同 GUID 的新端口替换旧服务，选择新端点；每次建立连接重新 NWBrowser 查当前服务，不保存端口 |
| 5. 同机 USB 优先 | 待用户验证 | 单测精确匹配关联 serial，排除其他 USB 手机；实际选择通过 os.Logger 的 ADBTransport 分类记录，暂无真机日志 |
| 6. 错误配对码提示、可重试 | 待用户验证 | 错误配对码、错误 exporter、密文篡改均拒绝；单测检查“配对码错误”，表单任务结束恢复输入；未操作真实手机界面 |

```text
$ make test
Test run with 15 tests in 0 suites passed
Test run with 26 tests in 0 suites passed
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

合计 41 项测试，命令退出码 0。M3 用两个子代理分别实现配对与发现，主进程负责 TLS/证书/界面/CLI 和整合验证。没有启动本地服务，没有 UI 自动化或快照测试。

SDK 核查：`nw_framer_prepend_application_protocol` 明确支持握手后动态插入 TLS；`SecIdentityCreate` 可直接结合系统生成的私钥和自签证书；无需更换 §6.2 的技术路线。未扩大 BoringSSL 调用范围。

## M4 GR IV USB

实现与自动检查通过；本机无相机，真机未测。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. USB 发现 GR IV | 待用户验证 | ICDeviceBrowser 只发现，不打开会话；接受官方文档中的 RICOH GR 发现名，连接时读取 DeviceInfo 确认 GR IV。CLI devices 退出 0、stdout/stderr 均为空，当前无设备 |
| 2. 两存储/DCIM、JPG/DNG 下载、删除或明确拒绝 | 待用户验证 | 14 项相机测试通过，涵盖真实字段映射、64 位容量、分块/范围读、删除刷新及 EACCES。ICC/GR 的实际 PTP data phase 布局、双存储暴露和删除能力均未实测 |
| 3. put/mkdir/mv 立即只读且不访问相机 | 待用户验证 | Provider 单元测试在连接前后检查 EROFS 且假相机调用次数不变；CLI 在创建 Provider 前直接拒绝这三类命令。真实 CLI 操作待用户用已保存连接验证 |

```text
$ make test
Test run with 16 tests in 0 suites passed after 0.043 seconds.
Test run with 26 tests in 0 suites passed after 0.362 seconds.
Test run with 14 tests in 0 suites passed after 0.008 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ build/bin/kayoi-dev devices
# stdout/stderr 均为空，退出码 0；当前 0 台设备
```

合计 56 项测试。两个子代理分别负责系统适配/Provider 和测试，主进程整合 App、CLI 与验证。

实现依据：本机 ImageCaptureCore SDK 的 contents/ptpObjectHandle/requestReadData/requestDeleteFiles/requestSendPTPCommand。目录沿用 ICC 原始树，仅通过标准 PTP GetStorageIDs/GetStorageInfo/GetObjectInfo 读取缺少的真实元数据；不会用文件总大小伪造容量。GetDeviceInfo 用于连接时确认型号。未知存储类型或无法读取必要字段时明确报错，不猜。

[RICOH 官方 FAQ](https://www.ricoh-imaging.co.jp/english/support/qa/gr-4/) 确认 Mac 使用 Image Capture、设备名为 RICOH GR；其 Windows 段注明不能从电脑删除。Mac 下的实际删除能力未获验证，因此仍按 PLAN.md 在相机拒绝时返回 EACCES，而不承诺一定能删。

## M5 阿里云盘

实现与自动检查通过；client_id/client_secret 尚未申请，没有真实授权或网盘写操作。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 官方授权、回调、昵称和容量 | 待用户验证 | 接入 ASWebAuthenticationSession，校验回调 route/state/code；OAuth/token/account 假实现与回调测试通过。构建产物确认 client_id/client_secret 均未配置，redirect URI 为 kayoi://oauth/aliyun |
| 2. >100分页、Range、>1GB分片及文件操作 | 待用户验证 | 单测覆盖101条分页、206/Content-Range、过期下载/上传链接重取、真实10MiB+17B两片数据、mkdir/move/trash；未上传真实 >1GB 文件或核对网页版 |
| 3. 无效 access_token 自动恢复 | 待用户验证 | 401/AccessTokenInvalid 刷新后仅重试一次，刷新令牌先写入钥匙串；假实现通过，未改真实账号令牌 |
| 4. 撤权后通知与重新登录状态 | 待用户验证 | 官方 PermissionDenied/刷新失败触发失效通知，App 显示重新登录；Core 测试确认错误不会覆盖重登状态。真实检测发生在下一次 App 请求时，未验证系统通知展示 |
| 5. 分页、缓存失效、分片边界单元测试 | 通过 | AliyunDrive 27项测试（OAuth13、文件13、回调1）；覆盖0字节、整片、最后不足一片、完整字节顺序及complete大小校验 |

```text
$ make test
Test run with 19 tests in 0 suites passed after 0.051 seconds.
Test run with 26 tests in 0 suites passed after 0.301 seconds.
Test run with 14 tests in 0 suites passed after 0.007 seconds.
Test run with 27 tests in 0 suites passed after 0.073 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ git check-ignore Config/Secrets.xcconfig
Config/Secrets.xcconfig
```

共 86 项测试。HTTP 的 URLProtocol 测试证明真实 URLSession AsyncBytes 在响应头返回后继续按 64 KiB 输出，不先加载整文件。普通请求与完整下载流共用最多4并发；429优先按官方 x-retry-after 毫秒退避。

配置：App 从本地 xcconfig 构建值授权；授权记录及客户端配置只存 `<UUID>.oauth` 钥匙串项，CLI 可用空配置恢复并刷新。connections.json 仅保存昵称、用户ID和通用连接字段，不存令牌。删除连接同时删对应钥匙串项。

用户已批准并已修订 PLAN.md：同名替换先完成新上传，再回收旧文件；上传失败不回收旧文件；旧文件回收失败或结果未确认时明确报错，不擅自删除新文件或回滚。原目录多份同名则拒绝猜选目标。接口不支持原位覆盖，file_id 会改变；网络中断时不能保证服务端回收未执行。

官方授权要求 style=folder；若返回 folder_id，Provider 将它作为根，绝不越过实际授权目录。跨目录且改名通常使用 move 后 update 两个官方调用；目标目录已有原名时，move 传最终 new_name，避免合法目标名被原名冲突挡住。整体不承诺原子性。来源见 THIRD_PARTY_NOTICES.md。

## M6 夸克

M6 实现与自动验证完成。M3 首次名称差异已获用户批准修订；F18 错误日志缺口已补齐，最终 `make test` 已通过 123 项测试。真机与界面结果仍待用户验证，不宣称全部实测通过。

| 验收 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 扫码登录、账号与容量 | 待用户验证 | 非持久化 WKWebView 读取 Cookie，账号与容量验证成功后才保存；手动 Cookie 入口已接入。没有真实扫码结果 |
| 2. 文件操作与 >100MB 上传 | 待用户验证 | 31 项 Quark 测试覆盖分页、Range、分片、哈希、上传完成、同名拒绝及 Cookie 生命周期；未进行真实上传 |
| 3. 删除 Cookie 后通知且不崩溃 | 待用户验证 | 假实现覆盖缺 Cookie、失效通知和 EACCES；系统通知与 UI 尚未实测 |

最终实际执行 `make test`（退出码 0），五包输出分别为 `24 / 26 / 14 / 28 / 31 tests passed`，合计 123 项通过。日志：`/tmp/kayoi-final-test.log`。
`make release` 输出 `** BUILD SUCCEEDED **`，随后签名校验输出 `valid on disk`、`satisfies its Designated Requirement`。日志：`/tmp/kayoi-final-release.log`（退出码 0）；开发工具另经 `codesign --verify --strict --verbose=2 build/bin/kayoi-dev` 校验通过。这些结果只代表自动测试与构建，不代表真实接口通过。

夸克仅参考 OpenList 接口行为，没有复制其代码。用户批准同名上传报错，旧文件不改动。账号接口 uid 字段尚缺真实响应确认；缺失时留空，没有从 Cookie 或昵称伪造 ID，因此 §7 用户 ID 的实际保存仍待核对。

最终核对发现并补齐 F18 日志缺口：连接测试、保存、列共享、推出及前置配对/授权失败接入现有系统日志和七天文本日志。只记录已知错误文案或数字错误码，未知错误不记录原始描述、URL 或 userInfo；回归覆盖错误回调、不额外发送挂载通知及敏感内容过滤。实际系统日志和文件显示仍需用户手验。

SMB 临时挂载点已移出可清理缓存目录，防止清缓存遍历到测试挂载；回归测试修改前失败、修改后通过（`/tmp/kayoi-cache-regression-before.log`、`/tmp/kayoi-cache-regression-after.log`）。此验证仅使用本地临时标记文件，没有真实远端删除操作。

## B3 官方开放平台网盘

B3 实现与自动检查完成；本地六组 client ID/secret 与百度 App ID 均为空，所以真实授权和远端文件操作全部待用户验证。

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 六个 Provider、能力声明和 App 接入 | 通过（自动检查） | 百度、115、123、OneDrive、Google Drive、Dropbox 均实现 `RemoteFileProvider`；App 与 `kayoi-dev` 已接入。`make build` 退出码 0 |
| 授权、令牌和刷新 | 通过（假实现） | 覆盖授权 URL、state、code 换取、401 刷新并只重试一次、115 独立 refresh URL、123 HTTP 200 业务鉴权刷新、瞬时刷新失败保留 refresh token、登录失效通知 |
| 分页与 Range | 通过（假实现） | 覆盖百度/115/123 分页、OneDrive nextLink、Google pageToken、Dropbox cursor；六种 Range 请求和错误响应状态检查 |
| 上传分片边界 | 通过（假实现） | 百度 4 MiB+1、115 2 MiB 自定义边界、123 服务端 sliceSize、OneDrive 320 KiB、Google 8 MiB、Dropbox 8 MiB；另测 Google 小文件 multipart |
| 同名与删除语义 | 通过（假实现） | 六个平台同名写入拒绝且不改旧文件；123 完成轮询 60 次后超时；删除接口分别使用删入回收站、trash、trashed 或 delete_v2 |
| 错误、限流和配置缺失 | 通过（假实现） | HTTP 状态保留原始码用于详情；429/503 按 Retry-After 重试；配额、权限、空间不足、多份同名和普通用户文案已映射；缺凭据不显示 client_id 等开发字段 |

```text
$ swift test --package-path Packages/CloudDrive
Test run with 35 tests in 0 suites passed
$ make build
** BUILD SUCCEEDED **
```

日志：`/tmp/kayoi-clouddrive-pkce2.log`、`/tmp/kayoi-polish-debug-current2.log`。35 项只证明假接口行为，不代表真实平台接口可用。官方接口来源和 rclone MIT 参考记录在 `docs/THIRD_PARTY_NOTICES.md`。

## B1 系统原生挂载

B1 的 SMB、WebDAV 和 NFS 路由已完成；真实 NetFS 服务仍需用户验证。

| 验收项 | 结果 | 证据与限制 |
| --- | --- | --- |
| SMB 改名和旧配置兼容 | 通过 | 界面名称改为“SMB 共享”，连接类型仍为原 `.smb` 和原参数，旧 `connections.json` 无需迁移 |
| HTTP/HTTPS WebDAV 与预设 | 通过（代码和假实现） | 自定义、坚果云、Nextcloud、群晖预设；HTTP 显示明文传输警告；用户名、密码和完整 URL 接入 NetFS |
| NFS | 通过（代码和假实现） | 服务器地址与导出路径组成 `nfs://host/path`；挂载表按实际 `host:path` 来源匹配 |
| NetFS 本机 WebDAV 实测 | 部分通过，待用户验证 | 同一临时 Basic Auth 服务用 `/sbin/mount_webdav` 直接挂载时 `mount_status=0`，能看到 `hello.txt` 并成功推出；`NetFSMountURLAsync` 对同一服务返回 `authentication`。未尝试降低验收或改成其它实现 |
| 自动挂载、推出、密码测试 | 通过（假实现） | Core 29 项中覆盖 WebDAV 保存、自动挂载、错误密码拒绝、测试挂载不影响已有挂载、推出失败保留配置 |

NetFS 依据本机 macOS 26.5 SDK `NetFS.h`。NFS 当前没有可用导出服务器，不能宣称真实挂载通过。

## B2 对象存储

B2 实现与自动检查完成，真实云账号、权限和网络行为待用户验证。

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 七种服务和寻址预设 | 通过（假实现） | AWS S3、Cloudflare R2、阿里云 OSS、腾讯云 COS、七牛 Kodo、MinIO、Backblaze B2；endpoint、region、virtual-hosted/path-style 均覆盖 |
| SigV4 和请求编码 | 通过（假实现） | 使用 CryptoKit；路径只编码一次；host 与签名头测试通过 |
| 目录、递归删除与移动 | 通过（假实现） | 无尾斜杠目录推断、跨页 `CommonPrefixes`、递归复制后删除、非空目录拒绝 |
| multipart 与未完成分页 | 通过（假实现） | 分片阈值和最后一片、`If-None-Match: *` 在 complete 阶段、409 竞态重传、缺少 next token 明确失败 |
| Range 和错误映射 | 通过（假实现） | 校验 206 与 `Content-Range`；XML ErrorCode、429/503/504/507 和条件冲突映射到 POSIX |

```text
$ swift test --package-path Packages/S3Drive
Test run with 12 tests in 0 suites passed
```

日志：`/tmp/kayoi-polish-debug-current2.log` 及本轮 `swift test` 输出。12 项只证明假接口行为。

## B4 实验性网页网盘

B4 的六个平台已接入；所有真实账号行为待用户验证。迅雷已接入官方阿里云 OSS Swift SDK，真实上传仍需账号验证。

| 验收项 | 结果 | 证据与限制 |
| --- | --- | --- |
| 夸克同源 UC | 通过（假实现） | Quark 参数化 `.quark/.uc`，独立域名、Cookie 过滤、API 域和 UA；Quark 32 项通过 |
| 天翼个人云/家庭云 | 通过（假实现） | SSON Cookie、会话、个人/家庭独立凭据、家庭选择、分页、Range、上传、目录/移动/删除；TianyiDrive 14 项通过 |
| 移动云盘 | 通过（假实现） | 手机号、网页 token、用户域容量、签名、分页、Range、分批上传、同名拒绝、目录/移动/删除；ChinaWebDrive 24 项中包含对应覆盖 |
| 迅雷云盘 | 通过（假实现） | 浏览、分页、Range、新建目录、移动、删除和阿里云 OSS multipart 通过假实现；创建任务只请求 `PROVIDER_ALIYUN`，SDK 启用 CRC64 与禁止覆盖，同名拒绝、非法厂商 endpoint 拒绝和失败清理均有覆盖 |
| PikPak | 通过（假实现） | 账号密码登录、token 持久化、分页、Range、分片、同名拒绝、错误映射；10 项通过 |
| 蓝奏云 | 通过（假实现，只读） | 账号 Cookie 与公开分享、密码、分页、Range、风控与错误映射；写操作立即 `EROFS`；5 项通过 |

```text
$ swift test --package-path Packages/Quark
Test run with 32 tests in 0 suites passed
$ swift test --package-path Packages/TianyiDrive
Test run with 14 tests in 0 suites passed
$ swift test --package-path Packages/ChinaWebDrive
Test run with 24 tests in 0 suites passed
$ swift test --package-path Packages/PikPakDrive
Test run with 10 tests in 0 suites passed
$ swift test --package-path Packages/LanzouDrive
Test run with 5 tests in 0 suites passed
```

迅雷接入官方 `alibabacloud-oss-swift-sdk-v2` `0.4.0`，没有复制 OpenList/AList 代码；来源与传递依赖见 `docs/THIRD_PARTY_NOTICES.md`。假实现不能替代真实迅雷账号、STS 和 multipart 验收。

## B5 通用 USB 相机

B5 实现与自动检查完成；没有真实相机，设备兼容性和删除能力待用户验证。

| 验收项 | 结果 | 证据与限制 |
| --- | --- | --- |
| ImageCaptureCore 本地 USB 发现 | 通过（假实现） | 仅接受 `productKind == Camera`，过滤 iPhone/iPad；插入、更新和移除通知覆盖 |
| 存储、DCIM 和 Range 读取 | 通过（假实现） | 真实存储列表与原始 DCIM 层级映射；Range 不返回额外字节；短读报错 |
| 写操作和删除 | 通过（假实现） | put/mkdir/move 在连接前即 `EROFS`；删除只在设备能力允许时尝试，拒绝时映射 `EACCES` |
| App、CLI 和类型入口 | 通过（代码） | 自动发现、`kayoi-dev devices`、添加类型卡片、表单和删除确认均接入；本轮修复了卡片遗漏和切换类型后沿用旧默认名的问题 |
| 真机品牌兼容 | 待用户验证 | 只用模拟对象测试；富士、索尼、佳能、尼康、理光等实际 PTP/MTP 元数据与删除能力未验证 |

```text
$ swift test --package-path Packages/CameraUSB
Test run with 12 tests in 0 suites passed
$ swift test --package-path Packages/RicohGR
Test run with 14 tests in 0 suites passed
```

## 待用户验证（按操作顺序）

目前 M1–M6、B1–B5 都有待测项目，M0 无待测项。请使用专门的测试共享、账号和不重要的文件。

1. **启动和面板（M1-1/2）**：在仓库执行 `open build/DerivedData/Build/Products/Release/Kayoi.app`。确认没有 Dock 图标，菜单栏可打开面板；无连接时显示空状态和添加按钮。分别切换系统浅色/深色；到系统“语言与地区”给 Kayoi 选英文后重启，检查文案与布局。
2. **准备 Windows（M1-3）**：在 Windows 开启文件和打印机共享；新建测试文件夹并共享，给测试账号读写权限，记下 IP、共享名、用户名与密码。微软账户使用邮箱和账户密码，不使用 PIN。
3. **列共享与错误密码（M1-3/5）**：添加 Windows 共享，填入主机、用户名、密码，点“列出共享”。先用错误密码点“测试并保存”，应提示“用户名或密码错误”，列表中不能新增连接；改为正确密码后保存。保存时会临时挂载再推出，此时不得影响已经挂载的共享。随后在系统已有 SMB 认证的情况下再次填写错误密码，确认仍拒绝保存。
4. **Finder 操作（M1-3）**：点击挂载，检查 Finder 的共享位置；拷入测试文件、拷出、新建目录、改名、删除；对照 Windows 目录内容。点击推出，确认 Finder 与面板挂载状态同步消失。
5. **编辑、排序、自动挂载和退出（M1-2/8）**：添加第二条有效连接，编辑名称/颜色，拖动行改变顺序；开启一条连接“打开 App 时自动挂载”，推出它并退出 App，再运行第 1 步命令。确认名称、顺序和开关保持，开启项自动挂载；App 退出不影响已挂载的 SMB 共享。
6. **Bonjour（M1-4）**：在同一局域网另一台 Mac 开启文件共享；用 `dns-sd -B _smb._tcp local.` 确认其正在广播（结束按 Ctrl+C），观察 Kayoi“已发现”，点击添加应预填主机和名称。
7. **删除密钥（M1-6）**：从 `~/Library/Application Support/Kayoi/connections.json` 找到测试连接 UUID，删除该连接。执行 `security find-generic-password -s com.seaony.Kayoi -a '<UUID>.password'`，预期查不到条目；不要使用会输出密码的 `-w` 或 `-g` 参数。
8. **开机自启（M1-7）**：将 Release App 复制到稳定位置（例如 `~/Applications/Kayoi.app`）并从该位置启动；打开设置、开启自动启动，若系统要求则到登录项设置允许。保存其他工作后注销再登录，确认菜单栏出现；关闭开关后重复验证不再启动。
9. **设置附加项（§4.4）**：查看日志目录，检查缓存显示与上限；清空缓存时必须先确认并成功推出已挂载共享。面板关闭时不应继续容量显示轮询。此项为手动检查，未声称通过。

10. **安卓准备与发现（M2-1/2）**：在手机开启开发者选项和 USB 调试，用数据线连接 Mac。先关闭可能占用设备的其它工具；必要时自行执行官方 `adb kill-server`。在 Kayoi“已发现”添加手机，测试并保存，手机弹框时点“允许”。再次测试应不再弹框；CLI 执行 `build/bin/kayoi-dev devices` 应显示同一序列号。拔出后面板应移除发现项。
11. **安卓文件操作（M2-3）**：从 connections.json 找到该连接 UUID，将下面的 `KAYOI_ID` 替换成它。在本地准备只含测试文件的目录（至少含子目录、中文、空格和 emoji 文件名）。执行：

```sh
KAYOI_ID='替换为连接UUID'
build/bin/kayoi-dev ls "$KAYOI_ID" /sdcard/DCIM
build/bin/kayoi-dev mkdir "$KAYOI_ID" /sdcard/KayoiAcceptance
build/bin/kayoi-dev put "$KAYOI_ID" '/本地测试目录' /sdcard/KayoiAcceptance/upload
build/bin/kayoi-dev mv "$KAYOI_ID" /sdcard/KayoiAcceptance/upload /sdcard/KayoiAcceptance/renamed
build/bin/kayoi-dev get "$KAYOI_ID" /sdcard/KayoiAcceptance/renamed '/本地下载目录'
build/bin/kayoi-dev rm -r "$KAYOI_ID" /sdcard/KayoiAcceptance
```

每步等 kayoi-dev 退出后，用官方 adb shell ls 检查手机结果。官方 adb 会启动自己的 server，检查完应执行 adb kill-server 再运行下一条 kayoi-dev，避免同时占用。不要在上述命令中使用重要目录。

12. **大文件哈希和速度（M2-4/5）**：选择一个大于 4 GB 的本地测试文件，记录 `stat -f %z '/本地大文件'` 和 `shasum -a 256 '/本地大文件'`。用 `put` 上传到专门测试目录，再用 `get` 下载到另一个本地文件，比较 SHA-256；退出 kayoi-dev 后用官方 `adb shell sha256sum '/sdcard/测试大文件'` 对照手机哈希。再用 USB 3 线和支持 USB 3 的手机 `get` 一个 1 GB 文件，记录 CLI 最终平均 MB/s、手机型号和线缆信息，目标 ≥20 MB/s。当前没有任何实测数值。
13. **中断和冲突（M2-6/7）**：传输大文件时拔线，确认命令报错退出、App 不崩溃且显示未连接；重插后重新测试。随后由用户启动官方 adb 并保持其占用，尝试 Kayoi 测试连接和 CLI，应提示“手机正被其它调试工具占用，请退出该工具或重新启动 Kayoi”；退出占用工具后重试。
14. **ADB 设置（§4.4）**：查看密钥指纹，重启后应保持不变。仅在愿意让全部手机重新授权时点击重新生成密钥并确认；之后手机应重新弹授权框。

15. **无线发现与配对（M3-1/2/6）**：让 Mac 与 Android 11+ 手机处于同一局域网，手机打开“无线调试 → 使用配对码配对设备”。在 Kayoi 添加安卓 Wi-Fi，选择配对服务，先输入错误六位码，确认提示“配对码错误”且能重试；再输入正确码并保存。手机“已配对的设备”应出现本机名称。必要时允许 macOS 的本地网络权限。
16. **无线文件操作（M3-3）**：拔掉 USB，使用 Wi-Fi 连接的 UUID 重复 M2 第 11、12 步，验证目录、中文/空格/emoji、大文件双向 SHA-256。不要沿用 USB 连接 UUID。
17. **端口变化（M3-4）**：关闭再打开手机无线调试，记录手机显示的新连接端口；保持原连接 UUID，在 App 测试连接并用 CLI ls，不能要求重新配对。
18. **USB 优先（M3-5）**：同机 Wi-Fi 可用时重新插上 USB，启动 `log stream --style compact --info --predicate 'subsystem == "com.seaony.Kayoi" AND category == "ADBTransport"'`，然后测试该 Wi-Fi 连接。应出现“连接方式：USB（优先于同机 Wi-Fi）”；拔出 USB 再测应出现“连接方式：Wi-Fi”。结束日志用 Ctrl+C。若 USB 被官方 adb 占用，先自行执行 adb kill-server。
19. **CLI 配对（§3.2）**：可单独执行 `build/bin/kayoi-dev pair '手机IP:配对端口' '六位码'`，成功输出 GUID；该命令只配对，不自动新增保存连接。随后从 App 已发现的连接服务添加，留空配对码，测试并保存。不要混淆手机显示的配对端口和连接端口。

20. **相机发现（M4-1）**：按理光官方 USB 步骤，先关闭相机，用数据线连接 Mac；相机会自动进入回放模式。先确认系统“图像捕捉”能看到 RICOH GR，再退出图像捕捉以避免并行占用。在 Kayoi 的已发现区添加并测试保存；执行 `build/bin/kayoi-dev devices`，记录相机名称和序列号。
21. **两存储、下载与容量（M4-2）**：确保内置存储和 microSD 各有可用于测试的 JPG/DNG。用 GR 连接 UUID 运行 `ls UUID /`、`ls UUID /内置存储/DCIM`、`ls UUID /microSD/DCIM`，再按实际返回路径执行 `stat UUID '/实际照片路径'` 和 `get UUID '/实际照片路径' '/本地下载文件'`。用 `stat -f %z '/本地下载文件'` 比较大小；运行 `df UUID` 记录相机报告的容量。若实际未暴露两个存储或 PTP 元数据返回错误，请保留错误，不能把单存储结果当两存储通过。
23. **只读拒绝（M4-3）**：使用 GR UUID 运行 `put UUID '/任意本地测试文件' '/new.JPG'`、`mkdir UUID /new`、`mv UUID '/已有照片路径' '/renamed.JPG'`。三者应立即报“此位置为只读”，不应出现部分上传或相机文件变化。界面仍由用户手动验收。

24. **准备阿里云盘配置（M5-1）**：申请开放平台 client_id/client_secret，登记与 `ALIYUN_REDIRECT_URI` 完全一致的回调地址。填写不入库的 `Config/Secrets.xcconfig`，参考 example 中 `$()` 的 URL 写法；执行 `make test && make release` 后重启 App。不要把凭据提交到 Git 或发到聊天中。
25. **授权和账号（M5-1）**：添加阿里云盘，测试并保存会打开官方授权页，按平台提示选择授权目录。完成后应自动回到 App，显示昵称与容量；若平台要求第三方应用权益，请按平台实际提示核实。
26. **文件与范围读取（M5-2）**：用阿里云盘连接 UUID 对一个超过100项的目录执行 `ls`，核对网页数量；对视频运行 `cat --range 1048576-2097151 UUID '/视频路径' > '/本地片段文件'`，预期片段1MiB。运行 `put` 上传一个 >1GB 测试文件并核对网页版大小，再验证 mkdir、mv、rm，删除项应进回收站。重复上传同名文件，确认新内容可见、旧项进回收站。
27. **令牌刷新（M5-3）**：在“钥匙串访问”中定位 service=com.seaony.Kayoi、account=`<UUID>.oauth` 的测试账号记录，保留 refreshToken 和其他字段，只把 JSON 中 accessToken 改为无效值；用 App 测试或 CLI ls，应自动恢复。不要导出或展示完整凭据记录。
28. **撤销授权（M5-4）**：在阿里云盘网页撤销测试应用授权，然后在 App 点击测试连接。应显示“重新登录”，并在已允许系统通知时收到通知；重新登录应重新走官方授权。没有请求时不承诺即时发现远端撤权。

29. **夸克登录（M6-1）**：添加夸克网盘，确认显示实验性提示，打开扫码页，用手机扫码；保存后核对昵称与容量。再验证手动粘贴 Cookie 入口；不要把 Cookie 发到聊天或提交 Git。检查配置中 userID 与真实账号响应是否一致，缺失时记录为未通过，不能用昵称替代。
30. **夸克文件操作（M6-2）**：用该连接 UUID 执行 `ls UUID /`、`df UUID`；对视频执行 `cat --range 1048576-2097151 UUID '/视频路径' > '/本地片段文件'`，核对 1 MiB。准备不重要且大于 100 MB 的新文件，依次执行 `mkdir UUID /KayoiAcceptance`、`put UUID '/本地文件' /KayoiAcceptance/upload.bin`、`get UUID /KayoiAcceptance/upload.bin '/本地下载文件'`，比较两端 SHA-256。重复 put 同一路径应报同名错误，旧文件内容不变；执行 `mv UUID /KayoiAcceptance/upload.bin /KayoiAcceptance/renamed.bin`、`rm UUID /KayoiAcceptance/renamed.bin`，逐步核对网页版及回收站。
31. **夸克 Cookie 删除（M6-3）**：在钥匙串访问中仅删除测试连接 service=com.seaony.Kayoi、account=`<UUID>.cookie` 的记录，再在 App 点击测试连接；应提示重新登录，在允许通知时收到系统通知，App 不崩溃。重新扫码应恢复。没有发请求时不承诺即时发现失效。

32. **准备 B3 开放平台配置（B3）**：分别申请百度、115、123、Microsoft、Google 和 Dropbox 的应用凭据，登记示例配置中的 `kayoi://oauth/...` 回调。复制 `Config/Secrets.example.xcconfig` 为 `Config/Secrets.xcconfig`，填入本地值；百度还要填 App ID。不要把凭据提交或发到聊天。执行 `make test && make release` 后启动 Release。
33. **六个平台授权（B3）**：逐个添加百度网盘、115 网盘、123 云盘、OneDrive、Google Drive、Dropbox。确认浏览器显示对应官方域名、完成后返回 App、昵称和容量可见；取消一次授权后应为安静取消，且随后新增其他网盘不会被迫重新授权。检查钥匙串 account 为 `<UUID>.oauth.<kind>`，但不要导出令牌。
34. **B3 文件操作（B3）**：对每个平台使用该位置 UUID 执行 `build/bin/kayoi-dev ls UUID /`、`df UUID`、`cat --range 0-1023 UUID '/测试文件'`、`put UUID '/本地测试文件' '/Kayoi测试/upload.bin'`、`get UUID '/Kayoi测试/upload.bin' '/本地下载文件'`、`mkdir`、`mv`、`rm`。每次在网页端核对名称、大小、回收站和最终内容；不要用重要文件。
35. **B3 同名与边界（B3）**：重复 `put` 同一路径，六个平台都应报同名错误且旧内容不变。准备 0 字节、恰好一个分片、分片加 1 字节和最后一片不足的文件，至少覆盖百度、123、OneDrive、Google、Dropbox；123 另测超过 10 GB 应拒绝。百度普通账号记录实际速度和文件大小限制说明是否准确。
36. **B3 刷新、限流和撤权（B3）**：在钥匙串测试记录中只把 access token 改为无效值，执行 `kayoi-dev ls` 应刷新并恢复；115 应请求独立刷新端点。制造或等待一次 HTTP 429/503 时确认按 Retry-After 重试并最终显示“服务请求过多”，不是权限错误。到平台网页撤销应用授权后再测试，应显示重新登录并通知；重新登录可恢复。

37. **WebDAV 实际挂载（B1）**：准备坚果云、Nextcloud、ownCloud、群晖、威联通或 OpenList/AList 的 WebDAV，优先使用应用密码。添加 HTTP 或 HTTPS WebDAV，保存时应临时挂载成功；随后点击挂载，在 Finder 完成新建、读取、改名和删除，最后推出。若 `NetFSMountURLAsync` 返回认证错误而网页凭据有效，请记录服务名称、URL 协议、系统版本和错误码。不要把密码写入命令或验收文档。
38. **NFS 实际挂载（B1）**：在 NAS 上给这台 Mac 配置只读或读写测试导出。添加 NFS，填写 NAS 地址和导出路径；测试并保存后检查 Finder、文件操作和推出。记录 NAS 型号、协议版本与挂载结果。
39. **对象存储（B2）**：为七种服务至少各测一个测试桶，执行 `build/bin/kayoi-dev ls/stat/get/put/mkdir/mv/rm`。准备 0 字节、16 MiB 整片和 16 MiB+1 字节文件；重复上传同名文件应报错且旧对象不变。核对 ListObjects 跨页、Range 的 1 KiB 片段、multipart 完成和删除后的网页或对象存储控制台结果。AWS/R2/OSS/COS/Kodo 还需记录 endpoint、region 与 bucket 是否匹配。
40. **UC 与天翼（B4）**：分别扫码登录 UC、填写天翼网页登录信息。天翼要分别保存个人云和家庭云，验证家庭云与个人云项目互不串用；对两个位置执行 `build/bin/kayoi-dev ls/stat/get/put/mkdir/mv/rm`，核对网页端和回收站。家庭账号有多个家庭云时，确认表单能选择正确家庭。
41. **移动、PikPak、蓝奏（B4）**：按表单把网页登录信息复制到钥匙串输入框，不粘贴到聊天或 Git。移动云盘验证容量、Range、上传和整理；PikPak 验证账号密码、分页、Range 和上传；蓝奏验证账号 Cookie 或公开分享链接、密码、Range，并确认所有写操作返回只读。
42. **迅雷上传（B4）**：保存迅雷连接后，用测试目录执行 `build/bin/kayoi-dev put <UUID> <本地文件> /测试目录/upload.bin`。先测 0 字节、一个完整分片和末片不足的文件，再测一个大于 1 GB 的文件；在迅雷网页端核对名称、大小和内容。重复上传同名文件必须报错且旧文件不变。上传中制造断网或取消，重新列出目录确认只清理本次新建的未完成条目，旧文件保持不动。
43. **通用相机（B5）**：使用一台 macOS“图像捕捉”能识别的富士、索尼、佳能、尼康或其它 PTP/MTP 相机。先退出图像捕捉，连接相机并允许存储访问；执行 `build/bin/kayoi-dev devices`，在 App 保存“相机（USB）”，再测试 `ls`、相机 / `DCIM` 路径、`stat`、Range `get`、`df` 和删除。若删除被拒绝，应保留 `EACCES`，并记录品牌、型号和系统能力，不能把拒绝改写成成功。
44. **最终界面手验（A）**：打开本仓库 `docs/screenshots/` 对照实际窗口，分别切换系统浅色/深色和中文/英文，检查菜单栏面板、28 种添加类型、设置、长名称截断、错误提示、键盘上下键与 Return、VoiceOver 标签、滚动区域和禁用态。扫码窗口、OAuth 窗口和真实错误状态需用真实账号触发。

## 未做与风险

- M7、M8 按要求不做。SMB、WebDAV 和 NFS 使用系统挂载；其余类型使用连接测试和开发工具。
- Windows 网络、密码验证、临时挂载与推出尚无实测。假实现只证明应用流程，不证明系统 API 在目标共享上的行为。
- 临时挂载点只用 `rmdir` 删除空目录；推出失败不会递归删除远端内容。若出现错误并留下临时挂载，请保留错误信息后用 Finder 推出对应卷。
- 仅安装了已授权的 XcodeGen，第三方代码仅使用已批准用途的 BoringSSL。未使用 Jev：本阶段是确定性的系统接口与编译检查。
- UI 采用系统字体、控件和 SF Symbols，按 §5 实现；未跑 UI 自动化或快照。未启动本地开发服务。

## M0 命令输出摘录

主目录 `make test`（退出码 0）：

```text
Test configurationLifecycle() passed after 0.001 seconds.
Test loginKeychainLifecycle() passed after 0.044 seconds.
Test run with 2 tests in 0 suites passed after 0.044 seconds.
```

新克隆 `make gen && make test && make release`（退出码 0）：

```text
Created project at /tmp/kayoi-m0-clone.Ki0yAJ/Kayoi.xcodeproj
Test configurationLifecycle() passed after 0.002 seconds.
Test loginKeychainLifecycle() passed after 0.041 seconds.
Test run with 2 tests in 0 suites passed after 0.041 seconds.
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

`PlistBuddy` 读取实际产物：`LSMinimumSystemVersion = 26.0`，`LSUIElement = true`。
`codesign -dv --verbose=2`：`Identifier=com.seaony.Kayoi`，`Format=app bundle with Mach-O universal (x86_64 arm64)`，`Authority=Apple Development: seaony@outlook.com (ZB4G2AWAU9)`。

核对 diff：仅 M0 工程、包空壳、存储与测试、构建说明及验收记录；PLAN.md 原文原样纳入首次提交。未实现 M7/M8、未增加本期之外的产品行为。

## 需求冲突与用户决定

- smbutil 的 `-A` 只做认证而不列共享，已获批准去掉；保存前另用 NetFS 新会话验证所填密码，允许临时挂载后推出，已有挂载不动。
- BoringSSL 用途经批准扩展到 Android 公钥编码 n0inv/rr；密钥生成、签名和 TLS 仍走系统框架。
- 阿里云盘不支持原位覆盖，经批准改为新文件完成后回收旧文件；原目录多份同名报错。
- 夸克同名上传经批准直接报错，不修改旧文件。
- M3 未配对发现拿到的是 ADB 服务名，已获批准首次显示服务名、保存后用自定义名称，并修订 PLAN.md。此前将这个明确差异仅标为待用户验证不准确，现已纠正。
- PLAN.md §6.6 同时要求扫码，又写“不提供手动粘贴 Cookie 以外的其它登录方式”，文字有冲突。实现遵循该段开头及 M6-1 明确要求：扫码为主，手动 Cookie 为备用入口；建议后续将否定句改为“不提供账号密码登录”。

格式检查：Swift 文件已使用 `xcrun swift-format format`。最终 `swift-format lint` 有 17 条命名风格警告（API 字段 snake_case、L 本地化函数及测试名称），没有格式错误；未为消除命名警告重构已完成阶段。`git diff --check` 无输出。

最终核对还修复了阿里云跨目录改名：目标目录已有原名但最终名空闲时，使用官方 move 的 new_name 参数，不修改原有同名文件。新增回归修前失败、修后通过；阿里云包 28 项通过，证据 `/tmp/kayoi-aliyun-move-red.log`、`/tmp/kayoi-aliyun-move-green.log`。真实账号按第 26 步补测 `/A/report.txt → /B/final.txt` 且 `/B/report.txt` 已存在的情形。

## 中英文与系统外观细节（2026-11-03）

本轮保留现有功能和系统跟随方式，没有新增语言/主题选择器，没有新增测试、UI 自动化或快照。

- 通过：现有 `make test` 共 123 项，退出码 0（`/tmp/kayoi-ui-test.log`）。
- 通过：`make release` 输出 `BUILD SUCCEEDED`，签名验证通过（`/tmp/kayoi-ui-release.log`）。
- 通过：英文挂载数量使用 String Catalog 单复数；Release 的 en.lproj/Localizable.stringsdict 已包含 one/other 规则。
- 已修改：行卡片和面板分别使用系统 controlBackgroundColor/windowBackgroundColor；长设备名可查看完整提示，操作按钮保持完整宽度；空状态覆盖手机、电脑、相机、网盘；取消支持 Escape，密钥指纹补充辅助功能标签。
- 待用户验证：退出旧进程后重新启动 Release；分别在中文/英文应用语言下切换系统亮色/暗色，检查菜单栏面板、添加窗口、设置和扫码窗口。使用长连接名称，确认操作按钮可见、悬停能看完整名称；检查键盘 Escape 取消、错误提示可读。未把编译成功视为这四种组合的视觉验收通过。

## 去除应用内玻璃样式（2026-11-03）

用户要求不用液态玻璃，覆盖原 §5 默认 bordered 按钮外观：保留 Button 和既有操作，使用实色填充、细边框和按下状态；窗口容器及扫码弹层指定系统实色背景，表单开关使用 checkbox。保留此前中英文及系统深浅色适配，不修改系统透明度设置。

- 通过：`make release` 退出码 0，`BUILD SUCCEEDED`，App 签名校验通过（`/tmp/kayoi-flat-release.log`）。
- 通过：现有 `make test` 123 项通过（`/tmp/kayoi-flat-test.log`）；未新增测试。
- 待用户验证：退出旧版后打开新版，在亮色和暗色分别检查面板、添加窗口、设置和扫码弹层。确认背景不透底、按钮无玻璃高光，并检查键盘焦点、禁用态和按下反馈。系统窗口边缘与弹出菜单的最终观感尚未实测，不把构建通过作为视觉通过。
- 未提交、未推送。未运行 UI 自动化或快照测试。

## 图标卡片与 SideMount 风格（2026-11-03）

用户明确要求类型选择使用图标卡片并进入下一步，后续指定 SideMount 为主要视觉参考。参考官方配对页及双设备面板的实色背景、绿色主操作、低对比边框与文字层次；未复制其代码或图标资源。

- 主要参考：https://sidemount.app/ 、https://sidemount.app/img/panel-pairing-dark.png 、https://sidemount.app/img/panel-two-phones-light.png 、https://sidemount.app/img/panel-two-phones-dark.png
- 初步参考：https://www.panic.com/transmit/ 、https://culturedcode.com/things/features/ 。最终配色以用户指定的 SideMount 为主。
- 类型选择：由五条长按钮改为三列图标卡片，选中标记与下一步；连接表单增加返回类型选择。均属用户本轮明确要求的选择流程。
- 表单：基本信息、连接信息、连接选项分组；字段标签与输入框上下排列；内容滚动，底部固定操作区。设置页补标题及说明。
- 源码尺寸：旧添加窗口宽460pt，现宽560pt；类型页高500pt，表单高620pt；卡片间距12pt、卡片高128pt、内容外边距24pt。以上为代码尺寸，未经实际截图测量。
- 检查5处 / 修改5处 / 未改0处：类型选择、连接表单、设置、主面板、扫码页。前三处调整布局，后两处仅统一颜色及按钮。实际渲染验证仍缺5处，不能据源码检查认定视觉通过。
- 通过：现有 `make test` 123项，退出码0（`/tmp/kayoi-cards-test.log`）；`make release` 与签名校验通过（`/tmp/kayoi-cards-release.log`）；`git diff --check` 无输出。
- 待用户验证：电脑控制读取 Kayoi 窗口返回 timeoutReached，未取得新版界面截图。请退出旧版后重新打开 Release，检查“添加位置”卡片未选/选中/下一步/上一步，SMB、Android、GR及两种网盘表单，设置页；分别检查中文/英文、深色/浅色、键盘焦点与错误提示。未新增测试、UI自动化或快照测试。
- 未提交、未推送。

## 打磨目标最终门禁（2026-11-04）

提交前重新执行 `make test` 和 `make release`，退出码均为 0。完整输出：`/tmp/kayoi-final-ship-test.log`、`/tmp/kayoi-final-ship-release.log`；`make release` 内含 `make gen`。

| 检查项 | 结果与实测 |
| --- | --- |
| 单元测试 | 通过。12 个 Swift 包共 243 项，0 失败：Core 31、ADB 26、RicohGR 14、AliyunDrive 28、Quark 32、S3Drive 12、CloudDrive 35、CameraUSB 12、PikPakDrive 10、LanzouDrive 5、TianyiDrive 14、ChinaWebDrive 24。 |
| Release 构建 | 通过。Xcode 输出 `** BUILD SUCCEEDED **`。 |
| App 签名 | 通过。`codesign --verify --deep --strict --verbose=2 build/DerivedData/Build/Products/Release/Kayoi.app` 输出 `valid on disk`、`satisfies its Designated Requirement`。 |
| DevTool 签名 | 通过。`codesign --verify --strict --verbose=2 build/bin/kayoi-dev` 输出 `valid on disk`、`satisfies its Designated Requirement`；`--help` 退出码 0，输出 12 行。 |
| 官方 SDK | 通过构建验证。迅雷上传使用 `alibabacloud-oss-swift-sdk-v2` `0.4.0` 的基础 `AlibabaCloudOSS` product；SwiftPM 解析并固定 Swift Crypto `3.15.1`、swift-asn1 `1.7.4`、XMLCoder `0.18.2`。没有 Team ID 时，Xcode 以 `CODE_SIGNING_ALLOWED=NO` 构建，再由 Makefile 用指定 Apple Development 身份签 App 和嵌套包。 |
| 产物结构 | 通过。主程序为 arm64 + x86_64 通用二进制；`LSMinimumSystemVersion=26.0`、`LSUIElement=true`；相机权限文案为通用的“发现并读取通过 USB 连接的相机。”。 |
| 编译警告 | 最终日志只有 1 条既有的 `appintentsmetadataprocessor` 提示“Metadata extraction skipped. No AppIntents.framework dependency found.”；没有 Swift 或 C 编译警告。 |
| 本地化 | 通过。`Localizable.xcstrings` 462 项：`L(...)` 缺键 0、英文缺失 0、简中缺失 0、复数变体缺失 0、未使用目录项 0。`InfoPlist.xcstrings` 的本地网络与相机权限均有简中、英文。Release 内已生成两种语言的 `Localizable.strings`、`Localizable.stringsdict` 和 `InfoPlist.strings`。 |
| 截图 | 文件检查通过，最新迅雷文案待重截。`docs/screenshots/` 共 62 张 PNG，空文件 0；其中面板、设置、类型选择器和迅雷以外表单仍可读取。迅雷表单两张截图生成于本轮“支持上传”文案修改前，不能当作最终视觉证据；电脑控制读取菜单栏窗口仍 `timeoutReached`，需要用户用最新 Release 手验。 |
| 新增鉴权回归 | 通过。`unauthorizedCloudErrorsAskForLogin()` 覆盖 UC、天翼、移动、迅雷、PikPak、蓝奏的 `unauthorized` 与 HTTP 401 文案；`webDriveAuthenticationFailureAsksForLogin()` 验证实验网盘鉴权失败会进入 `needsLogin` 并触发登录过期回调。 |
| 提交前审查修复 | 通过构建和现有测试。迅雷 `kayoi-dev put` 不再在 Provider 创建前被拒绝；跨源重定向删除 `Authorization`、`Cookie`、`SessionKey`、`Signature`、`Space-Authorization` 等已知认证头；网页登录和夸克登录在任务先取消时立即结束；123 云盘列表不会为同名文件缓存单一 ID；云端改名失败会清掉相关路径缓存；移动云盘上传失败会清理本次创建的远端条目；OneDrive/Google 取消上传会话；S3 递归移动和多种分片上传失败时用未取消的清理任务执行补偿。各平台仍不承诺跨目录改名是一次原子操作，失败时会返回错误并清缓存，执行前应避免把重要文件放在测试目录。 |
| 差异检查 | 通过。`git diff --check` 无输出。 |
| 最新 Release 启动 | 通过。已退出旧进程并启动本次签名构建 `build/DerivedData/Build/Products/Release/Kayoi.app`，进程 PID `15236`。 |

逐条实现和假实现证据见 `docs/POLISH-REPORT.md`。真实 Windows 共享、WebDAV/NFS、开放平台账号、B4 账号、安卓手机、相机和系统通知仍按本文“待用户验证”顺序执行。

迅雷上传已按用户批准接入官方阿里云 OSS Swift SDK，自动测试覆盖任务参数、同名拒绝、失败清理、非法 endpoint 和分片边界。真实 STS、真实文件、长文件、同名竞态和限流仍待用户按第 42 项验证；迅雷 API 仍属实验性网页接口。

## 0.2 待用户验收补充：天翼

在用户自行配置的个人云与家庭云测试账号中，分别按原第 40 项操作：准备包含中文、空格、`+`、`#` 和表情名称的小文件，验证下载链接为 HTTPS 时可读取，范围读取内容与原文件一致；新建及改名后的加号不得变为空格。在文件多于一页的目录中对照网页总数和末页名称，确认无漏项。若远端分页返回不一致，应显示失败而不是声称目录完整。每次只处理一个小测试文件，再核对网页结果。本轮没有连接真实账号，这些项目均未验收。

## 0.2 待用户验收补充：授权刷新

以下未连接真实账号，仅有本地替身与独立测试进程证据：

- 待用户验收：公共授权类网盘、阿里云盘、PikPak、天翼分别在 App 与 kayoi-dev 使用同一测试账号并发读取时，刷新后两边继续可用，不互相进入重新登录状态。
- 待用户验收：断网、限流或服务故障后保留登录，恢复网络后可重试；只有服务端明确拒绝刷新授权时要求重新登录。阿里云盘的普通权限不足不应当作撤销登录。
- 待用户验收：系统钥匙串实际拒绝保存新凭据时明确报错；在进程继续运行、存储恢复后重试能够补存。此场景不通过退出应用来测试内存恢复，未保存值不能保证在进程异常退出后保留。
- 待用户验收：删除位置后，其授权凭据不会因先前失败的补存而重新出现。实际菜单栏点击及系统钥匙串提示仍需用户操作确认。

本地证据见 `OPTIMIZATION-REPORT.md` 的 FIX-06、FIX-07 记录；真实账号凭据不得写入验收截图或日志。

## 0.2 待用户验收补充：设备会话恢复

- 待用户验收：安卓 USB 与无线连接查询不存在的文件或遇到权限拒绝后，继续列目录正常，不需要重新添加位置。
- 待用户验收：传输过程中拔线后明确报错；重新插入并重连时使用新传输，列表和下载恢复。无线调试端口改变后重新解析端点，不继续使用旧端口。
- 待用户验收：需要手机重新授权时显示真实授权状态；USB 优先选择仍只匹配同一台手机。以上没有进行真机操作，本地证据见 FIX-08 的假传输回归。

## 0.2 待用户验收补充：设备移动冲突

- 待用户验收：使用可丢弃的测试文件，将文件或目录移动到已存在的文件、目录、悬空链接时应明确提示目标已存在，源与目标内容保持不变。
- 待用户验收：缺失目标的中文、空格、引号及 emoji 路径可正常移动；确认设备的 mv 支持所需选项。旧命令不支持时应报错，不回退为无保护覆盖。
- 本地替身验证不能证明外部应用同时更改目标时的原子防覆盖；Toybox 的存在性检查与 rename 之间仍有并发窗口，不能将普通冲突测试描述成原子保证。

## 0.2 待用户验收补充：设备上传中断保护

- 待用户验收：用可丢弃的原文件测试覆盖上传，在中途拔线或取消后确认原内容不变；恢复连接后检查同目录是否留下 `.kayoi-upload-*.tmp`，不可将临时文件误认成已提交文件。
- 待用户验收：旧版与新版安卓设备分别测试零字节文件、中文/引号路径、空间不足和目标为目录；成功时新内容替换精确目标，失败时原文件保留。
- 待用户验收：设备支持所用 mv 选项，提交失败能明确报错；在设备仍可访问时临时文件会尝试清理，断线时不能保证已删除临时文件。未进行真实文件上传或设备断线操作。

## 0.2 待用户验收补充：迅雷与移动云盘回收站

- 待用户验收：每个平台先准备一个可丢弃的小文件，通过 Kayoi 删除后，在官网回收站找到它并恢复，核对原内容；再单独验证空目录。每次只操作一个目标。
- 待用户验收：非递归删除非空目录应被拒绝；允许递归删除后应能从官网回收站恢复目录内容。回收站请求被拒绝时不得自动永久删除。
- 待用户验收：若账号空间、保险箱或服务版本不支持回收站，应报错并保留数据，不走永久删除回退。具体保留期限以账号官网提示为准。
- 公开官网客户端的请求核对与本地方法/路径/正文断言已完成，证据见 FIX-10；本轮没有登录真实网盘、上传测试文件或删除真实文件。

## 0.2 待用户验收补充：蓝奏下载与精确大小

- 待用户验收：账号文件、单文件分享和目录分享分别使用一个测试文件，比较 Kayoi 属性大小与下载后实际字节数；包含页面显示 KB/MB、文件名带数字和零字节文件。
- 待用户验收：读取文件尾部及跨过页面估算大小的范围，不丢尾部数据；服务不支持范围时明确报错，不能把完整响应当成指定片段。
- 待用户验收：链接要求网页验证时不能保存 HTML 验证页冒充原文件；正常 HTML 附件仍可下载并保持内容。
- 待用户验收：不同下载站点的 HEAD/范围响应兼容性及目录加载耗时。缺少可核实的长度时应报错，不应显示假 0 字节。以上本轮均未使用真实账号或分享链接验证。

## 0.2 待用户验收补充：编辑系统挂载地址

- 待用户验收：SMB、WebDAV、HTTPS WebDAV、NFS 已挂载时修改地址，保存前旧卷被推出，不遗留旧卷、不误发意外断开通知；新位置处于与实际挂载一致的状态。
- 待用户验收：旧卷无法推出时明确报错，旧地址和凭据不被替换；仅改名称、颜色不推出卷。
- 本轮已用假挂载回调检查保存与推出顺序，未操作任何真实系统卷或服务器。


## 0.2 待用户验收补充：挂载超时后的迟到成功

- 待用户验收：系统挂载超时或取消后，若成功回调迟到，应自动推出其返回的卷，不把它们登记为成功挂载；正常完成的挂载仍保留。
- 待用户验收：卷被占用等原因导致推出被系统拒绝时，检查隐私保护的系统错误日志，并由用户关闭占用后手动推出。清理失败不得阻止其余返回卷的推出，也不得把原超时改成成功。
- 本轮只以替身回调验证顺序和失败处理，未连接服务器或操作真实卷。


## 0.2 待用户验收补充：挂载表地址匹配

- 待用户验收：SMB 中文和空格共享名、组合重音字符、主机名大小写不同的挂载仍被正确识别；WebDAV 地址协议名大小写不同不应误报断开。
- 待用户验收：NFS 的系统挂载来源格式、带字面百分号的路径与实际共享对应。两个名称仅路径大小写或字面百分号不同的卷不能混为一个位置。
- 本地已用纯字符串夹具验证匹配，未读取真实挂载表或连接共享。


## 0.2 待用户验收补充：S3 查询与写入保护

- 待用户验收：用测试桶验证多页目录、特殊字符对象键，包含中文、加号和百分号；分页继续完整列出，签名不报错。此次官方签名向量仅在本地计算验证，没有发送至 AWS。
- 待用户验收：每次只测试一个可丢弃对象，普通文件、空文件、分片上传及目录标记遇同名对象时应报已存在，原内容不变；新名字仍正常写入。无 HEAD 权限或 HEAD 失败时应停止，不继续覆盖。
- 待用户验收：分片上传期间由测试账号创建同名对象，完成前检查应停止并中止本次分片，保留已有对象；确认服务中没有遗留本次未完成分片。
- 不支持或忽略条件写入的服务只能依赖写前检查，HEAD 与实际写入之间仍有并发窗口；此类服务请避免多个写入者同时写同一对象，不把本地替身测试当成服务端原子保证。

## 0.2 待用户验收补充：会话复用

- 待用户验收：使用测试账号反复执行连接测试和登录校验；更改名称不丢失登录，重新登录后后续测试使用新凭据。蓝奏更换分享地址/密码、移动更换账号信息后，后续操作不能继续使用旧配置。
- 待用户验收：天翼个人登录与家庭空间选择分别有效，更换家庭空间后读取正确空间；关闭未保存的登录草稿、删除保存位置后，重新进入时没有遗留的旧会话状态。
- 四并发上限及共享会话中单个 provider 断开后的行为已用本地替身测试；本轮没有真实账号并发传输证据，不能据此宣称服务端限流、Cookie 续期和网络中断行为全部通过。

## 0.2 待用户验收总矩阵（UA-02）

以下项目全部**未进行真实验收**，也不由本地替身、旧截图或源码检查替代。使用可丢弃的小测试文件，从小范围开始，每次一个操作并对照服务官方界面。不得把真实凭据、Cookie、密钥或文件内容放进截图和日志。这里只给用户操作步骤，不授权任何自动访问真实API。

| 编号 | 用户操作步骤 | 预期结果与需记录内容 |
|---|---|---|
| UA-02-MENUBAR | 点击真实菜单栏Kayoi图标，依次打开、关闭，再开添加/设置；拥挤菜单栏隐藏图标时从Spotlight或Finder再次打开Kayoi。 | 面板入口可用、位置正确、Esc关闭、快捷键不冲突；四种状态图标及VoiceOver标签准确。记录是否真实点击成功；普通演示窗口截图不能替代这一项。 |
| UA-02-SYSTEM-01 | 分别用Windows 11本地账户、微软账户，macOS共享，群晖或威联通NAS测试SMB；另测WebDAV/HTTPS WebDAV/NFS。先挂载，再退出Kayoi。 | 系统卷继续由Finder使用；退出无推出确认，不自动eject。用户名/密码错误应明确失败，不保存错误凭据。 |
| UA-02-SYSTEM-02 | 挂载后在Finder主动推出；另在可控网络断开后检查状态，再恢复网络。 | 主动推出不报意外断开；异常消失正确提示；网络恢复后符合自动挂载设置的位置最多自动重试一次，不重复挂载。 |
| UA-02-SYSTEM-03 | 修改已挂载共享地址，再测试取消、旧卷被占用不能推出、仅改显示名称/颜色。 | 改地址先推出旧卷；失败保留旧配置和凭据；不留孤儿卷、不发假通知；只改显示资料不推出。 |
| UA-02-SYSTEM-04 | 使用中文、空格、组合重音、字面百分号及路径大小写不同的共享；新建/删除少量测试文件后再次打开面板。 | 正确匹配各卷，不混淆字面百分号；可用容量按实际变化刷新，面板关闭不持续轮询。 |
| UA-02-SYSTEM-05 | 系统睡眠/唤醒、Wi-Fi换网、断网/恢复和VPN切换分别执行；测试中取消或退出。 | 失效状态及时更新，恢复不使用旧端点；退出取消测试/授权/配对并完成必要临时挂载清理，不影响原系统卷。 |
| UA-02-SYSTEM-06 | 在可控共享环境观察挂载超时/取消后迟到成功；若卷占用阻止清理，先关闭占用再手动推出。 | 迟到卷被清理或明确记录清理失败，不被登记为正常挂载；无法推出不阻断其他卷清理；日志不含凭据。 |
| UA-02-ANDROID-01 | Android 11至当前版本中至少两个版本，Pixel/三星/小米或红米/OPPO或一加/vivo至少三个品牌；每台分别USB-C直连和扩展坞连接。 | 发现、允许调试、连接测试、文件操作正常；记录品牌/型号/Android版本/接法，不能只验一台。 |
| UA-02-ANDROID-02 | 用仅充电线、拒绝调试授权、授权等待超时分别测试；插入鸿蒙NEXT设备。 | 给可执行提示，不无期限等待；鸿蒙NEXT明确不支持ADB，不伪装支持；超时/取消后界面恢复。 |
| UA-02-ANDROID-03 | 同一手机同时开USB和Wi-Fi调试，再拔USB；两台序列号重复设备分别接入。 | 优先同一设备USB，切换后不误报另一台断开；重复序列号按位置身份区分，不能连接错设备。 |
| UA-02-ANDROID-04 | 查询不存在路径/无权限路径后立即继续列目录；传输中拔线再重连。 | 普通文件错误不废会话；传输错误后重建连接，恢复后正常；设备测试成功或连接中拔线会通知。 |
| UA-02-ANDROID-05 | 用可丢弃文件测试移动到同名文件/目录/悬空链接，再测试上传覆盖中断、取消和空间不足。 | 冲突不覆盖、不移进错误目录；上传失败原内容保留；检查`.kayoi-upload-*.tmp`残留，断线清理不能保证成功须明确。 |
| UA-02-ANDROID-06 | 分别在v1/v2协议设备验证>4GB限制、范围下载、修改时间、df可用量；英文界面访问既有`SD 卡`/`内置存储`路径。 | 不静默截断，不改旧路径；仅显示名翻译；设备能力不支持时明确拒绝。 |
| UA-02-ANDROID-07 | 对照手机授权弹框与设置显示的指纹；确认重生成后逐设备重新授权；用测试文件测USB读写速度。 | 指纹算法及值含义准确，不误称SHA256与MD5相同；吞吐记录文件大小/耗时/设备/接法，目标20MB/s，未达需瓶颈说明。 |
| UA-02-CAMERA-01 | GR IV和至少一台富士/索尼/佳能/尼康通用相机各连接一次，切换设备USB/PTP/MTP模式。 | GR只出现一次；打开会话后能力正确，真实容量未知不显示0；设备错误有对应操作提示。 |
| UA-02-CAMERA-02 | 无序列号相机、相同序列号多机、慢目录相机分别连接、断开、重连；允许/拒绝系统相机权限。 | 位置ID兜底稳定、不串设备；慢目录有截止与取消；重连可恢复；权限被拒提示并可打开系统设置。 |
| UA-02-CAMERA-03 | 按能力读取、复制和删除一个可丢弃照片；目录包含异常条目时观察错误。 | 不跳过文件伪称完整目录；只读相机不提供写操作；允许删除的相机实际执行正确，失败不报成功。 |
| UA-02-OAUTH-01 | OneDrive、Google、Dropbox使用公共/原生客户端注册完成授权，再触发一次过期刷新。 | 不依赖静态secret；OneDrive/Dropbox公共客户端开关正确；Google实际反向clientID回调返回App，旧kayoi回调不再使用。 |
| UA-02-OAUTH-02 | 每个OAuth服务点击“切换账号”，明确选另一个测试账号；授权时把Kayoi放后台，另测用户取消。 | 不静默回到原账号；授权锚定编辑窗口，后台也可弹出；取消不保存新账号或遗留进度。 |
| UA-02-OAUTH-03 | 核对Google Drive scope和开发者控制台审核状态；阿里/百度/115/123按各自平台配置授权。 | 真实注册接受当前回调和权限；需secret的平台桌面二进制无法保密，按DECISIONS记录风险；不打印任何配置值。 |
| UA-02-CLOUD-01 | 阿里、百度、115、123、OneDrive、Google、Dropbox、夸克、UC、天翼、移动、迅雷、PikPak、蓝奏各用一个真实测试账号。按PLAN §8逐项测列表/stat/范围读/上传/建目录/改名/移动/删除；只读类型只测允许项。 | 文件名分别含中文、空格、emoji、+、#；对照官网大小、名称、内容、分页和回收站。每类型单独记录，不能一家代表所有。 |
| UA-02-CLOUD-02 | 各账号断网/恢复、临时限流后重试；App与kayoi-dev共用同一凭据记录并发读取；触发真实登录失效。 | 暂时错误保留登录；只有明确授权失效才重登录；并发刷新不互相作废、不重复通知；进度属于正确操作。 |
| UA-02-CLOUD-03 | 天翼、移动、迅雷在应用内网页登录；各测验证码、扫码过期、风控、加载失败、取消和其他登录方式；天翼个人/家庭空间分别验证。 | 正确捕获并先验证登录再保存；不误存失败凭据、不在日志中输出Cookie；切换空间和账号不复用旧会话。 |
| UA-02-CLOUD-04 | 迅雷、移动各创建一个可丢弃小文件，Kayoi删除后到官网回收站恢复；随后单独测空目录和非空目录。 | 确实进入回收站；非递归非空拒绝；回收站不支持/被拒时不回退永久删除。 |
| UA-02-CLOUD-05 | 夸克/UC/天翼/移动/PikPak跨目录改名，分别准备目标已有原名、源目录已有最终名、目标已有最终名；中途断网后刷新官网。 | 不误操作同名目标；恢复失败明确最后确认位置/临时名，不能谎称已恢复；异步任务未完成不报成功。 |
| UA-02-CLOUD-06 | 百度测试分页stat、下载权益、秒传/空文件、上传同名与不同VIP分片；115测试临时OSS端点、203回调失败、同名不同ID；123测试长时间完成轮询。 | 百度fs_id对应正确；115回调失败时可能对象已存在，先官网核对再重试；重名不删错；123无进展截止明确，服务实际长处理兼容性另记录。 |
| UA-02-CLOUD-07 | Google目录含重复名、斜杠名、点名称、保留前缀；移动虚拟ID路径并在重名消失后再次访问；OneDrive移动到根目录并中断/恢复分片上传。 | 每个文件均可区分且身份不串；CLI应显示必要的操作路径；Google原名保留，308按已确认范围续传；OneDrive根ID与上传会话正确。 |
| UA-02-CLOUD-08 | 蓝奏账号、单文件分享、有密码目录分享分别下载，含页面估算大小、零字节、正常HTML附件与网页验证页；编辑清空分享密码后故意测试失败。 | 长度来自真实响应，尾部不丢；验证页不冒充文件，HTML附件仍可下载；失败保存不删除旧密码；Cookie续期后重新打开仍可用。 |
| UA-02-CLOUD-09 | 对照各服务官网总量、已用和可用容量，尤其Google无限账户、S3未知、移动容量单位、115容量变化。 | 未知不显示假0、不出负数；移动单位须实际对比后才能确认，不凭静态字段名猜倍率。 |
| UA-02-CLOUD-10 | 迅雷SDK用小文件逐步到大文件测试上传、取消、磁盘不足、分片失败；PikPak测0字节与验证码恢复。 | 不整块5GiB驻留内存；临时分片和服务端未完成上传清理有结果；SDK内部真实峰值与进度另记录。 |
| UA-02-S3-01 | AWS及实际使用的S3兼容服务分别验证路径式/虚拟主机式地址、本地MinIO受支持的连接方式、R2真实账户地址。 | pathStyle正确，占位地址不能保存；不将未知桶容量显示0；真实签名和分页含+/%/中文完整。 |
| UA-02-S3-02 | 测试已有目标、普通/空文件、目录标记和分片上传；上传期间另建同名目标。 | 已有数据保留，HEAD失败不继续；支持条件头的服务拒绝竞态，忽略条件头的服务仍有检查到写入之间窗口，不声称原子保证。 |
| UA-02-S3-03 | 先小文件确认，再用可丢弃>5GiB对象做移动，含用户metadata与标签；测试标签权限不足、分片失败、源内容改变。 | UploadPartCopy成功完成后才删源，标签/metadata不丢；失败保留源；不支持标签读取明确失败；条件删除支持需各服务分别确认。 |
| UA-02-S3-04 | 用小测试目录递归删除并在第二个对象制造权限拒绝或断网；刷新官网。 | 报告确认删除数量、失败对象未知状态和未尝试对象；无法回滚不能伪称全成功。无版本桶永久删除、有版本桶删除标记按官网确认。 |
| UA-02-S3-05 | 范围读取跨EOF/起点在EOF，服务临时503后恢复，复制中取消并检查未完成分片。 | 只返回剩余字节或空流；有限退避可取消；没有无穷重试，未完成分片清理失败明确提示。 |
| UA-02-KEYCHAIN | 系统钥匙串拒绝保存刷新结果时留进程运行，恢复权限后重试；再删除该位置并观察是否重新出现凭据。 | 新令牌不丢且恢复后补存；删除后不复活；进程异常退出不能承诺恢复尚未写盘值。保存/清密码/配置失败不得误删旧凭据。 |
| UA-02-ENV-01 | 13寸1470×956到外接4K、多屏菜单栏在副屏、断开外屏后重新打开窗口；系统26.x实际版本记录。 | 所有窗口可用且不越屏；面板最高560；记忆位置恢复到当前屏幕；刘海/拥挤菜单栏有重开入口。 |
| UA-02-ENV-02 | 运行中切浅深色，增强对比度、减弱动态效果、VoiceOver、全键盘控制分别开启；中英与伪语言，地区美国/中国/德国。 | 状态、图标、边框清楚，文字不截断；只键盘完成添加SMB→测试保存→挂载→Finder→推出→删除；面板行朗读为完整句。 |
| UA-02-ENV-03 | 拒绝本地网络、相机、通知权限；测试登录项被系统阻止；许可证资源无法加载场景用演示/本地夹具验收。 | 原因明确并有正确设置入口，不静默失败；设置五页状态与添加窗口说明一致。 |
| UA-02-ENV-04 | 用户具备Developer ID后按RELEASING完成时间戳、公证、staple及首次下载打开；在可控环境执行正式更新来源验证。 | 记录真实签名身份与系统Gatekeeper结果；本轮不推送、不发布，Apple Development本地验证不冒称已可公共分发。 |

上述 UA-02 保留真实验收边界。2026-11-05 收尾范围已调整：三次测试、覆盖率、Release 和签名/架构门禁已通过；截图补全、性能长测和本地 Sparkle 演练按用户清单不再执行，见下方待验项。


### 最后代码补充：上传恢复与本地对象存储

以下仍为待用户验收，20个客户端定向测试不能证明真实服务的会话寿命、存储效果或账户权限。

| 编号 | 操作 | 预期与边界 |
|---|---|---|
| UA-02-CLOUD-11A | Google测试大于单片的小测试文件，上传中断网恢复，另测上传会话自然过期、最终响应丢失，再对照官网文件内容与哈希。 | 有效会话先查询已确认位置继续；失效会话重建前查同名、从0重传，不声称保留失效分片；不会覆盖已有同名或无限恢复。 |
| UA-02-CLOUD-11B | OneDrive测试网络中断、服务繁忙、会话失效及最终目标已有同名；恢复后下载对比。 | 依服务端nextExpectedRanges续传；失效重建次数有界、仍严格拒绝冲突；uploadURL不携带OAuth头；真实账户及会话关闭结构需核对。 |
| UA-02-CLOUD-11C | Dropbox测试append/finish阶段会话过期、响应丢失和已关闭会话。 | incorrect_offset按服务端确认游标恢复；过期最多重建一次且从0传，仍mode=add、不自动改名、不覆盖；closed不创建另一个文件。逐次对照网页避免重复结果。 |
| UA-02-CLOUD-11D | 115测试临时OSS凭据过期发生在单PUT、初始化、分片、完成四阶段；先一个小文件，再验证实际回调。 | 只有明确SecurityTokenExpired重新取STS并重签当前步骤一次，保留uploadID和成功片；权限错误不冒充过期。真实签名接受与远端哈希仍需账号确认。 |
| UA-02-CLOUD-11E | 百度和123先验证访问令牌失效后续传，再在可控账号中等待上传任务ID自然失效或由官网关闭后重试。 | 已知访问令牌刷新保留任务ID、片号、正文。uploadID/preuploadID本身过期的确切错误码、可恢复性和片保留规则尚未证实；不猜错误码、不盲目create新文件。记录官网可见结果和无敏感数据的错误码，再决定支持策略。 |
| UA-02-S3-06 | 用本地名称、.local、局域网IP或回环地址访问HTTP MinIO；另试公网HTTP和内嵌用户密码地址，不发送真实密钥至公网。 | 前后端同一策略只允许本地HTTP，公网必须HTTPS；实际ATS允许本地请求，Host端口和签名正确。完整公网域名即使解析私有IP仍需HTTPS，不全局关闭ATS。 |
| UA-02-CAPABILITIES | 连接只读蓝奏/通用相机，改变连接地址后重测，再测试允许删除的相机。 | 只读来自实际连接后ProviderCapabilities，参数改变不沿用旧能力；可删除相机不误称全部只读。演示只用固定假能力；阶段一面板没有远端写文件入口。 |

非授权kayoi://链接不受支持：PLAN只将它定义为OAuth回调，本轮没有新增通用深链功能。用户只需验真实OAuth授权可返回App，不将未知链接打开指定位置列为承诺。


## 收尾门禁与待用户验收（2026-11-05）

最终门禁通过：diff 检查、工程生成、连续三次完整测试、覆盖率（包 87.49%、App 85.74%）、Release 及应用/CLI 双架构、签名、CLI bundle、最低 macOS 26.0。日志为 `build/Validation/final-diff-check.log`、`final-gen.log`、`final-test-{1,2,3}.log`、`final-coverage.log`、`final-release.log`、`final-release-validation.log`；均退出 0。本地开发签名不代表正式发行公证。

| 项目 | 状态及验收步骤 |
|---|---|
| 拖动排序 | 2026-11-05 面板改为两列卡片后复测通过：Debug 演示 mixed 场景，用 HID 级真实鼠标事件把 smb 卡片拖到 quark 前，顺序变为 …aliyunDrive、smb、quark…；拖动中按 Esc、拖出窗口松手后顺序均不变，源卡片恢复。此前两次失败为工具事件不带按键状态及坐标落在底栏，非应用问题。真实菜单栏面板里的拖动仍待用户目检。 |
| 增强对比度 | 待用户验收：公开 API 无法模拟，需用户在系统设置开启后目检面板/添加/设置浅深色边框与分隔线。本轮未改系统设置；失效旗标与只检查名字的旧测试已删。 |
| 删除确认与无线错误详情 | AX 证据正确；删除框截图白图，无线详情超出单窗口截图边界，完整视觉未通过。用户可目检原生弹窗；本轮不再重拍。 |
| 其它截图缺口 | 待用户验收；只读行/菜单、许可证、缓存确认、菜单栏/应用图标、剩余键盘与预览等未补矩阵，按收尾清单停止扩展。旧失败图不计通过。 |
| 线性条与复用窗口标题 | 既有修后复核通过；三张 UI-WEB-01-loading-fixed 浅/深/返回浅图显示对应绿色，UI-EDIT-03-from-discovery-dark-zh.png 显示“添加位置”和 Pixel 8。只引用交接现场结果与本轮原图核对，不冒充最终 Release 重新实测。 |
| Sparkle 升级演练 | 未做，按清单不启动回环服务。准备目录 `/var/folders/9z/gvnyl5hj1vn2kn84cy5j7gwr0000gn/T/kayoi-update-rehearsal-4uv7x6rq` 包含 `REVIEW.md`、`isolation.patch`、`0.2.0/Kayoi.app`、`0.2.1/Kayoi.app`、`feed/appcast.xml`、`feed/Kayoi-0.2.1.zip`。后续明确允许演练后，按 REVIEW：前台运行 serve-loopback-after-approval.py，仅绑定 127.0.0.1:43871；启动独立临时 0.2.0 应用，手动检查→下载→安装→重启，核对 0.2.1 与独立 bundle ID，结束退出应用并停止服务。不读取临时私钥，不开启正式更新源。 |
| 性能长测 | 未做，按清单停止长时测试。稳定 Demo Release 后用 `python3 scripts/sample-process.py --pid <演示进程PID> --seconds 300 --interval 1 --output build/Validation/perf-panel-closed.json`，分别测关闭/打开面板 CPU；稳定性改为 1800 秒；50 次开合记录真实次数并对比稳定起止 RSS。测量期间不构建；CPU 100% 为单核，RSS 不等于 footprint。启动/面板时延也没有本轮实测数值，软件绘制探针用法见 PERFORMANCE.md。 |

## M7 第二步，第 1 小步：存储迁移（2026-11-11）

环境：macOS 27.2、Xcode 27.2，付费团队自动签名的 Debug。此处只验收存储和 CLI 接入，FSKit 正式卷尚未接入。

| 项目 | 状态 | 现象与证据 |
|---|---|---|
| 单元测试与完整构建 | 通过 | `make build` 和整包签名校验通过；最终 `make test` 退出 0，916 项 Swift 测试和 14 项脚本测试通过，523 个实际本地化键通过检查。日志：`build/m7-step1-build.log`、`build/m7-step1-test.log`。 |
| 迁移成功、部分失败、重复运行 | 通过 | Core 150 项测试包含复制后读回核对、写失败保留全部旧值后续跑、迁移后新配置与刷新令牌不被重复迁移覆盖，以及新旧值冲突停止。 |
| 共享存储不可用时留在旧位置 | 通过 | 三项新增测试覆盖共享钥匙串不可写、共享目录不可写、共享探测成功且不触发迁移；原配置和 ADB 钥匙保持。另将临时 App 移除描述文件后重签，命令行正常进入，系统日志确认使用传统存储，无迁移错误或 GUI 弹窗。 |
| 本机首次真实迁移前备份 | 通过 | 正常退出原 Debug 后复制整个旧数据目录到 `build/backup-20261111-205438/`，3 个文件逐字节核对一致；备份未修改。 |
| 本机配置、日志、钥匙迁移 | 通过 | 迁移日志记录 3 个文件、1 个传统钥匙串条目核对通过；共享配置有 1 个 Android USB 连接，配置与备份逐字节一致，两份历史日志完整。旧配置已清理，`security find-generic-password -s com.seaony.Kayoi -a adb.private-key` 返回条目不存在。spike 文件与测试钥匙留到第 8 步。 |
| CLI 保持命令行为 | 通过 | 15 项 CLI 测试覆盖配置位置、双语错误、无描述文件的兼容 App、真实 exec 参数及输出、退出码转交。实际构建的 `build/bin/kayoi-dev --help` 正常；不存在的连接返回原“路径无效”。双架构 CLI 构建用本机可用的 Apple Development 身份签名，未修改发布流程。 |
| 手机与远端文件操作 | 未测 | 本步不做 Finder 传输验收。迁移后 App 自动连接曾返回 EACCES，尚未查明原因；第 5 小步再验证手机授权和通信。 |
| 正式分发与 macOS 26 | 未测 | 本轮只验收带描述文件的 Debug；当前 Release 继续旧存储、不带 FSKit 扩展，正式分发签名另行决定。macOS 26 未实测。 |

### 第 1 小步审查补正与旧版兼容恢复

- 通过：传统钥匙串查询明确指定 `kSecUseDataProtectionKeychain=false`。本机带共享权限的临时程序已复现默认查询能搜到共享条目、显式传统查询搜不到的差异；回归用例先失败，修改后通过。
- 通过：迁移失败后，本次回退旧存储并继续启动，下次重试。测试包含失败后继续编辑配置、刷新令牌，以及部分钥匙已复制后旧值变化；迁移记录只保存名称与 SHA-256，重试只能覆盖属于本次迁移且未被另改的副本，未知冲突仍保留两端数据。
- 通过：最终 `make build`、签名校验、`make test` 退出 0，919 项 Swift 测试与 14 项脚本测试通过，Core 为 153 项。日志：`build/m7-startup-build.log`、`build/m7-startup-test.log`。未改动的 HTTP 流释放用例曾失败一次，单独复跑及最终全量均通过，未扩大修改；单独复跑日志为 `build/m7-unrelated-stream-retry.log`。
- 通过：按用户决定把备份的配置原样恢复到旧位置，并把共享原值复制回传统 `com.seaony.Kayoi / adb.private-key`；文件和钥匙均读回一致，系统传统钥匙串查询已确认存在。新位置、spike 与备份未改，恢复工具留在忽略目录，未提交。没有另外启动旧版 App；本步仅核对指定恢复项。
- 未测：真实迁移失败弹窗及关闭弹窗后继续运行的界面。失败选择与重试用注入故障的单元测试核对，未为界面验收修改真实数据制造冲突。

## M7 第二步，第 2 小步：真实文件系统骨架

| 项目 | 状态 | 现象与证据 |
|---|---|---|
| 构建、测试和签名 | 通过 | 最终 `make build`、深度签名校验、`make test` 退出 0；934 项 Swift 测试、14 项脚本测试通过，App 165 项、Core 166 项。实际扩展 23 个 scheme 与源配置一致，USB/网络/共享组及两条 IOKit 例外仍在签名中。日志：`build/m7-step2-build-final.log`、`build/m7-step2-test-final.log`。 |
| URL、配置、身份与 Provider 分发 | 通过（代码及本地检查） | 声明 23 个 scheme，涵盖 24 种非系统连接；USB/Wi-Fi 共用 adb scheme，GR 保持原行为。测试遍历所有连接种类，核对保存连接解析、类型不匹配和带凭据 URL 拒绝。扩展默认共享配置及密钥，ADB 身份显式传到 USB/TLS/握手。未把构造器编译通过当作真实服务通过。 |
| 目录与读取缓存 | 通过（本地替身） | 设备 5 秒、网盘 30 秒缓存及写/改名/删除失效通过；Range、空文件、EOF、整文件复用、跨连接 LRU 配额通过。下载预留计入默认 5 GB 上限，写入暂存单独保存且不淘汰。 |
| 写入、权限与失败路径 | 通过（本地替身） | 关闭与 flush 上传、失败保留本地内容、只读 EROFS、断线 EIO、同卷请求串行、完整上传及 stat 校验后才删旧、失败后保留恢复文件、编辑器替换改名顺序均通过。文件 mtime 传入实际上传文件；重复目录操作路径返回 EEXIST，不崩溃、不选错对象。 |
| 真实 FSKit 对象回调 | 通过（本地测试） | 两项适配器测试使用真实 FSVolume/FSItem 类：外部修改后属性刷新，非 POSIX 登录失效映射 EACCES；关闭上传 ENOSPC 原样回到 SDK 回调，本地未上传字节读回一致。回调锁外执行，列目录不返回点项。 |
| 真机挂载、Finder 传输与云盘账号 | 未测 | 第 3 小步覆盖层尚未实现，本步不在真卷上拷贝，避免生成远端元数据。安卓、网盘与对象存储的真实验收分别留到第 5 至 7 小步；本机只有一个已保存的安卓 USB 连接。 |
| macOS 26 与容量未知 | 未测 | 部署目标为 26，采用旧 Operations 接口；本机系统为 27.2，26 未实测。未知容量保留 SDK 默认 0，未伪造容量，Finder 对未知容量的实际行为留待有账号时核对。 |

## M7 第二步，第 3 小步：本地元数据覆盖层

| 项目 | 状态 | 现象与证据 |
|---|---|---|
| 构建、测试和签名 | 通过 | `make build`、深度签名校验和完整 `make test` 通过；942 项 Swift 测试、14 项脚本测试通过，App 166 项、Core 173 项。日志：`build/m7-step3-build.log`、`build/m7-step3-test.log`。 |
| 系统元数据文件 | 通过（本地替身） | 五类保留名称与其子路径均存入按连接 ID 隔离的 Overlay，创建、随机读写、截断、改名、删除、同步及重开读回通过；目录只合并本地元数据项，不暴露镜像中间目录。没有远端元数据写入。 |
| 扩展属性 | 通过（本地及真实 SDK 对象） | 属性名称与字节完整读回，创建、替换、移除策略及连接隔离通过；真实 FSVolume 回调核对根目录和普通文件的属性，远端移动、删除同步属性路径。没有拦截 `._*` 文件名。 |
| 只读和断线 | 通过（本地替身） | 本地元数据在只读或断线 Provider 下仍能读写，普通远端文件继续按能力拦截；跨本地与远端的改名返回 EXDEV 并保留原项。 |
| Finder 实际元数据行为 | 未测 | 本步只核对覆盖层和 SDK 回调；Finder 真卷创建、拷贝及不生成远端 AppleDouble 的实测留到第 5 小步。 |

## M7 第二步，第 4 小步：主 App 挂载与推出

| 项目 | 状态 | 现象与证据 |
|---|---|---|
| 构建、测试与签名 | 通过 | `make build`、深度签名、完整 `make test` 退出 0；968 项 Swift 测试和 14 项脚本测试通过，App 186 项、Core 179 项，538 个本地化键通过。日志：`build/m7-step4-build.log`、`build/m7-step4-test.log`。 |
| 挂载分发与原生请求 | 通过（本地替身） | 27 与 26 分支、禁用拦截、类型与 UUID 匹配、取消后的迟到成功清理、立即退出等待清理、缓存维护门禁、未知容量不伪报 0 均通过。尚未用真卷冒充这些测试。 |
| 自动挂载、设备变化与保存 | 通过（本地替身） | 所有实际挂载类型走幂等挂载，Wi-Fi 返回恢复自动连接；设备消失取消正在挂载的任务并调用推出处理。已挂卷保存原凭据不重复连接，改变参数时推出失败不写新配置或密钥；GR 仍走原测试路径。 |
| 退出与推出失败 | 通过（本地替身） | 仅清理本次自挂非 SMB 系统卷，SMB 与预先挂载卷保留；FSKit 迟到请求先收尾。EBUSY 时取消退出并恢复操作，可继续推出和重新挂载。 |
| 登录失效与缓存安全 | 通过（本地测试） | 真实分布式通知只使已保存 FSKit 云连接进入重新登录状态，重复通知一次，刷新挂载表不清除。Read 可统计和清理，Overlay/Writes 保留；损坏、不可读或符号根抛错，不假报零。沙盒扩展实际投递与真实非零缓存尚未实测。 |
| 原生界面 | 通过（演示布局与组件） | 真实 Debug 演示面板、通用设置、英文深色编辑页已截图，新增自动挂载与 Finder 开关有无障碍文字证据；组件宿主的中英浅深四图核对了 F3 横幅与 F15 四态，无截断重叠。截图位于 `build/m7-step4-{panel-light,settings-light,editor-dark}.png` 和 `build/agents/fs-ui/screenshots/`。未操作 Dia 或模拟鼠标点击。 |
| 真机及系统版本 | 未测 | 手机实际挂载、Finder 传输、Wi-Fi、拔插、真实退出清理留到第 5 小步。系统设置实际跳转未操作；26 未实测。 |
